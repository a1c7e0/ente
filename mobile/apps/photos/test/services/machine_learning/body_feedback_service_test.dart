import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:photos/db/ml/body_feedback_db.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/body_feedback.dart";
import "package:photos/models/ml/face/box.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/services/machine_learning/body_feedback_service.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:sqlite_async/sqlite_async.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SqliteDatabase sqlite;
  late BodyFeedbackDB db;
  late _Remote remote;
  late BodyFeedbackService service;
  int? owner = 1;
  String? token = "session-a";

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    ServiceLocator.instance.init(
      await SharedPreferences.getInstance(),
      Dio(),
      Dio(),
      Dio(),
      PackageInfo(
        appName: "Photos",
        packageName: "photos",
        version: "1",
        buildNumber: "1",
      ),
    );
  });
  setUp(() async {
    owner = 1;
    token = "session-a";
    directory = await Directory.systemTemp.createTemp("body_feedback_");
    sqlite = SqliteDatabase(path: "${directory.path}/feedback.db");
    db = BodyFeedbackDB.forTesting(sqlite);
    await db.migrate(sqlite, BodyFeedbackDB.schema);
    remote = _Remote();
    service = BodyFeedbackService(
      db: db,
      ownerID: () => owner,
      token: () => token,
      files: (ids) async => {
        for (final id in ids)
          if (!remote.missing.contains(id))
            id: EnteFile()
              ..uploadedFileID = id
              ..ownerID = 1,
      },
      updateMetadata: remote.write,
      setManualAssignment: (id, fileID, assigned) async {
        final person = remote.persons[id]!;
        final manual = person.data.manuallyAssigned.toSet();
        if (assigned) {
          manual.add(fileID);
        } else {
          manual.remove(fileID);
        }
        remote.persons[id] = person.copyWith(
          data: person.data.copyWith(manuallyAssigned: manual.toList()),
        );
      },
      storeIndex: (id, index) async {
        remote.stored[id] = index;
      },
    );
  });
  tearDown(() async {
    await sqlite.close();
    await directory.delete(recursive: true);
  });

  test(
    "local acknowledgement needs no network and survives database reopen",
    () async {
      await service.enqueue({7: _accept()});
      expect(remote.writes, isEmpty);
      final path = "${directory.path}/feedback.db";
      await sqlite.close();
      sqlite = SqliteDatabase(path: path);
      db = BodyFeedbackDB.forTesting(sqlite);
      final pending = await db.pending(1);
      expect(pending.single.fileID, 7);
      expect(pending.single.patch.manual, {"person": true});
      expect(
        pending.single.patch.toJson().toString(),
        isNot(contains("embedding")),
      );
      expect(await db.pending(2), isEmpty);
    },
  );

  test(
    "pull overlays preserve generated vectors and unknown remote fields",
    () async {
      await service.enqueue({7: _accept()});
      final downloaded = _index();
      downloaded.raw["futureField"] = {"keep": true};
      downloaded.detections.single.raw["futureDetection"] = "keep";
      final projected = await service.overlay({
        7: jsonEncode(downloaded.toJson()),
      });
      final index = BodyIndex.tryParse(jsonDecode(projected[7]!))!;
      expect(index.detections.single.decisions["person"]["status"], "accepted");
      expect(
        index.detections.single.embedding,
        downloaded.detections.single.embedding,
      );
      expect(index.raw["futureField"], {"keep": true});
      expect(index.detections.single.raw["futureDetection"], "keep");
      expect(index.toJson().containsKey("pending"), isFalse);
      expect(await service.manualChanges(), {
        "person": {7: true},
      });
      expect(BodyFeedbackService.applyManualChanges([9], {7: true, 9: false}), {
        7,
      });
    },
  );

  test(
    "successful sync preserves other mldata and supplies legacy manual tags",
    () async {
      await service.enqueue({7: _accept()});
      await service.flushWhileLocked();
      expect(await db.pending(1), isEmpty);
      expect(remote.persons["person"]!.data.manuallyAssigned, [7]);
      expect(remote.metadata[7]!.remoteRawData["future"], "preserved");
      expect(remote.metadata[7]!.remoteRawData["clip"], {"unknown": true});
      expect(
        remote
            .metadata[7]!
            .bodyIndex!
            .detections
            .single
            .decisions["person"]["status"],
        "accepted",
      );
      expect(remote.stored.keys, [7]);
    },
  );

  test(
    "offline failure retains intent and later ordinary sync retries it",
    () async {
      remote.failures.add(7);
      await service.enqueue({7: _accept()});
      await service.flushWhileLocked();
      expect((await db.pending(1)).length, 1);
      expect(remote.stored, isEmpty);
      remote.failures.clear();
      await service.flushWhileLocked();
      expect(await db.pending(1), isEmpty);
      expect(remote.persons["person"]!.data.manuallyAssigned, [7]);
    },
  );

  test(
    "undo during an in-flight acceptance survives its acknowledgement",
    () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      remote.beforeWrite = (id) async {
        if (remote.writes.length == 1) {
          entered.complete();
          await gate.future;
        }
      };
      await service.enqueue({7: _accept()});
      final flush = service.flushWhileLocked();
      await entered.future;
      await service.enqueue({7: _undo()});
      gate.complete();
      await flush;
      expect(await db.pending(1), isEmpty);
      expect(remote.writes, [7, 7]);
      expect(remote.persons["person"]!.data.manuallyAssigned, isEmpty);
      expect(
        remote.metadata[7]!.bodyIndex!.detections.single.decisions,
        isEmpty,
      );
    },
  );

  test(
    "old acknowledgements cannot delete a replacement even after discard",
    () async {
      await db.enqueue(1, {7: _accept()});
      final first = (await db.pending(1)).single;
      await db.discardFiles(1, [7]);
      await db.enqueue(1, {7: _undo()});
      await db.acknowledge(first);
      expect((await db.pending(1)).single.revision, isNot(first.revision));
    },
  );

  test("a person reset removes only that person's pending changes", () async {
    final patch = _accept().merge(
      BodyFeedbackPatch({
        "body:7": {
          "decisions": {
            "other": {"status": "rejected"},
          },
        },
      }, {}),
    );
    await db.enqueue(1, {7: patch});
    await db.discardPerson(1, "person", [7]);
    final pending = (await db.pending(1)).single;
    expect((pending.patch.bodies["body:7"]["decisions"] as Map).keys, [
      "other",
    ]);
    expect(pending.patch.manual, isEmpty);
  });

  test(
    "full reset discards only selected photos and account records",
    () async {
      await db.enqueue(1, {7: _accept(), 8: _accept()});
      await db.enqueue(2, {7: _accept()});
      await service.discardFiles([7]);
      expect((await db.pending(1)).map((item) => item.fileID), [8]);
      expect((await db.pending(2)).length, 1);
      await db.clear();
      expect(await db.pending(1), isEmpty);
      expect(await db.pending(2), isEmpty);
    },
  );

  test(
    "an old session cannot publish local results or acknowledge pending work",
    () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      remote.beforeWrite = (_) async {
        entered.complete();
        await gate.future;
      };
      await service.enqueue({7: _accept()});
      final flush = service.flushWhileLocked();
      await entered.future;
      owner = 2;
      token = "session-b";
      gate.complete();
      await expectLater(flush, throwsStateError);
      expect(remote.stored, isEmpty);
      expect(remote.persons["person"]!.data.manuallyAssigned, isEmpty);
      expect((await db.pending(1)).length, 1);
      expect(await service.manualChanges(), isEmpty);
    },
  );

  test(
    "failed photos do not block others; writes stay bounded at four",
    () async {
      remote.failures.add(1);
      var active = 0;
      var peak = 0;
      remote.beforeWrite = (_) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        active--;
      };
      await service.enqueue({for (var id = 1; id <= 11; id++) id: _accept()});
      await service.flushWhileLocked();
      expect(peak, lessThanOrEqualTo(4));
      expect((await db.pending(1)).map((item) => item.fileID), [1]);
      expect(remote.persons["person"]!.data.manuallyAssigned.toSet(), {
        for (var id = 2; id <= 11; id++) id,
      });
    },
  );

  test(
    "changed remote grouping remains pending instead of overwriting it",
    () async {
      final index = _index();
      index.detections.single.raw["groupID"] = "body-group:changed";
      remote.metadata[7] = FileDataEntity.empty(7, DataType.mlData)
        ..putBody(index);
      await service.enqueue({7: _accept()});
      await service.flushWhileLocked();
      expect((await db.pending(1)).length, 1);
      expect(
        remote.metadata[7]!.bodyIndex!.detections.single.groupID,
        "body-group:changed",
      );
    },
  );

  test(
    "a transaction cannot enqueue edits after the session is invalidated",
    () async {
      await expectLater(
        db.enqueue(1, {7: _accept()}, isCurrentSession: () => false),
        throwsStateError,
      );
      expect(await db.pending(1), isEmpty);
    },
  );

  test("patches produced by accept and undo coalesce without vectors", () {
    final original = _index();
    final accepted = BodyIndex.tryParse(
      jsonDecode(jsonEncode(original.toJson())),
    )!;
    accepted.detections.single.bindReviewGroup("body-group:test");
    accepted.detections.single.decisions["person"] = {
      "status": "accepted",
      "addedManual": true,
    };
    final first = BodyFeedbackPatch.between(original, accepted);
    expect(first.manual, {"person": true});
    final undone = BodyIndex.tryParse(
      jsonDecode(jsonEncode(accepted.toJson())),
    )!;
    undone.detections.single.decisions.clear();
    final combined = first.merge(BodyFeedbackPatch.between(accepted, undone));
    expect(combined.manual, {"person": false});
    combined.apply(original, checkGroup: true);
    expect(original.detections.single.decisions, isEmpty);
    expect(jsonEncode(combined.toJson()), isNot(contains("embedding")));
  });

  test(
    "local feedback preserves other devices' decisions on the same body",
    () async {
      final downloaded = _index();
      downloaded.detections.single.decisions["other"] = {"status": "rejected"};
      await service.enqueue({7: _accept()});
      final projection = await service.overlay({
        7: jsonEncode(downloaded.toJson()),
      });
      final decisions = BodyIndex.tryParse(
        jsonDecode(projection[7]!),
      )!.detections.single.decisions;
      expect(decisions["person"]["status"], "accepted");
      expect(decisions["other"]["status"], "rejected");
    },
  );

  test(
    "queued regrouping accepts its own intermediate group, not another device's split",
    () {
      final newer = BodyFeedbackPatch({
        "body:7": {
          "expectedGroup": "body-group:test",
          "groupID": "body-group:split",
          "decisions": {},
        },
      }, {});
      final merged = _accept().merge(newer);
      for (final group in [null, "body-group:test", "body-group:split"]) {
        final remoteIndex = _index();
        if (group != null) remoteIndex.detections.single.raw["groupID"] = group;
        merged.apply(remoteIndex, checkGroup: true);
        expect(remoteIndex.detections.single.groupID, "body-group:split");
      }
      final conflicting = _index();
      conflicting.detections.single.raw["groupID"] = "body-group:unrelated";
      expect(
        () => merged.apply(conflicting, checkGroup: true),
        throwsStateError,
      );
    },
  );

  test("undo never removes an unrelated manually assigned photo", () {
    final before = _index();
    before.detections.single.decisions["person"] = {
      "status": "accepted",
      "addedManual": false,
    };
    final after = BodyIndex.tryParse(jsonDecode(jsonEncode(before.toJson())))!;
    after.detections.single.decisions.clear();
    expect(BodyFeedbackPatch.between(before, after).manual, isEmpty);
  });
}

BodyFeedbackPatch _accept() => BodyFeedbackPatch(
  {
    "body:7": {
      "expectedGroup": null,
      "groupID": "body-group:test",
      "decisions": {
        "person": {"status": "accepted", "addedManual": true},
      },
    },
  },
  {"person": true},
);
BodyFeedbackPatch _undo() => BodyFeedbackPatch(
  {
    "body:7": {
      "decisions": {"person": null},
    },
  },
  {"person": false},
);

BodyIndex _index() => BodyIndex(100, 200, [
  BodyDetection(
    bodyID: "body:7",
    box: const FaceBox(x: 0.1, y: 0.1, width: 0.5, height: 0.8),
    score: 0.9,
    embedding: List.filled(512, 0.1),
    decisions: {},
    raw: {},
  ),
]);

class _Remote {
  final persons = {"person": PersonEntity("person", PersonData(name: "Alex"))};
  final metadata = <int, FileDataEntity>{};
  final stored = <int, BodyIndex>{};
  final writes = <int>[];
  final failures = <int>{};
  final missing = <int>{};
  Future<void> Function(int)? beforeWrite;
  Future<FileDataEntity> write(
    EnteFile file,
    bool Function(FileDataEntity) update,
  ) async {
    final id = file.uploadedFileID!;
    writes.add(id);
    await beforeWrite?.call(id);
    if (failures.contains(id)) throw StateError("offline");
    final current = metadata.putIfAbsent(
      id,
      () => FileDataEntity.empty(id, DataType.mlData)
        ..putBody(_index())
        ..remoteRawData["future"] = "preserved"
        ..remoteRawData["clip"] = {"unknown": true},
    );
    final copy = FileDataEntity.empty(id, DataType.mlData)
      ..remoteRawData.addAll(
        jsonDecode(jsonEncode(current.remoteRawData)) as Map<String, dynamic>,
      );
    update(copy);
    metadata[id] = copy;
    return copy;
  }
}
