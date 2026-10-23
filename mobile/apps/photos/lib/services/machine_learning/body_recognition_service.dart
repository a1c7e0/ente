import "dart:convert";
import "dart:typed_data";

import "package:logging/logging.dart";
import "package:photos/db/files_db.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/models/base/id.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/body_feedback.dart";
import "package:photos/models/ml/face/box.dart";
import "package:photos/models/ml/face/face.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/body_feedback_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/face_thumbnail_generator.dart";
import "package:photos/services/machine_learning/ml_model_download_service.dart";
import "package:photos/services/search_service.dart";
import "package:photos/src/rust/api/ml_indexing_api.dart" as rust;
import "package:photos/utils/ml_util.dart";

class BodyRecognitionService {
  static final instance = BodyRecognitionService._();
  BodyRecognitionService._();
  final _logger = Logger("BodyRecognitionService");
  Map<int, String> _rawIndexes = {};
  Map<int, BodyIndex> _parsedIndexes = {};
  int _indexRevision = 0;
  String? _matchKey;
  List<BodyMatch> _matches = const [];

  Future<BodyIndex> analyze(int fileID, String path, List<Face> faces) async {
    final result = await rust.analyzeBodiesRust(
      fileId: fileID,
      imagePath: path,
      assetsDir: await MLModelDownloadService.instance.getAssetsDirectory(),
    );
    return fromRust(result, faces);
  }

  static BodyIndex fromRust(rust.RustBodyIndex result, List<Face> faces) {
    final usedFaces = <String>{};
    final bodies = <BodyDetection>[];
    for (final body in result.detections) {
      final xyxy = body.boxXyxy;
      final box = FaceBox(
        x: xyxy[0],
        y: xyxy[1],
        width: xyxy[2] - xyxy[0],
        height: xyxy[3] - xyxy[1],
      );
      final contained = faces.where((f) {
        final fb = f.detection.box;
        final cx = fb.x + fb.width / 2;
        final cy = fb.y + fb.height / 2;
        return f.score > 0 &&
            cx >= box.x &&
            cx <= box.x + box.width &&
            cy >= box.y &&
            cy <= box.y + box.height;
      }).toList()..sort((a, b) => b.score.compareTo(a.score));
      if (contained.length > 1) continue;
      final faceID =
          contained.length == 1 && !usedFaces.contains(contained.first.faceID)
          ? contained.first.faceID
          : null;
      if (faceID != null) usedFaces.add(faceID);
      bodies.add(
        BodyDetection(
          bodyID: body.bodyId,
          box: box,
          score: body.score,
          embedding: body.embedding,
          linkedFaceID: faceID,
        ),
      );
    }
    return BodyIndex(result.width, result.height, bodies);
  }

  Future<void> store(IMLDataDB<int> db, int fileID, BodyIndex index) =>
      db.putBodyIndex(fileID, jsonEncode(index.toJson()), index.version);

  Future<void> publish(
    IMLDataDB<int> db,
    EnteFile file,
    BodyIndex generated,
  ) async {
    final fileID = file.uploadedFileID!;
    final entity = await fileDataService.updateFileData(file, (latest) {
      if (latest.bodyIndex != null || latest.hasUnsupportedBody) return false;
      latest.putBody(generated);
      return true;
    });
    final raw = entity.remoteRawData["body"] as Map<String, dynamic>;
    await db.putBodyIndex(
      fileID,
      jsonEncode(raw),
      (raw["version"] as num).toInt(),
    );
  }

  Future<Map<int, BodyIndex>> indexes() async {
    final data = await BodyFeedbackService.instance.overlay(
      await MLDataDB.instance.bodyIndexes(),
    );
    if (identical(data, _rawIndexes)) return _parsedIndexes;
    if (data.length == _rawIndexes.length &&
        data.entries.every((e) => _rawIndexes[e.key] == e.value)) {
      return _parsedIndexes;
    }

    final result = <int, BodyIndex>{};
    for (final entry in data.entries) {
      try {
        final index = BodyIndex.tryParse(jsonDecode(entry.value));
        if (index != null) result[entry.key] = index;
      } catch (e, s) {
        _logger.warning("Ignoring invalid body index ${entry.key}", e, s);
      }
    }
    _rawIndexes = data;
    _parsedIndexes = result;
    _indexRevision++;
    return result;
  }

  void invalidateCaches() {
    _rawIndexes = {};
    _parsedIndexes = {};
    _indexRevision++;
    _matchKey = null;
    _matches = const [];
  }

  Future<List<BodyMatch>> matches(List<EnteFile> files) async {
    final indices = await indexes();
    if (indices.isEmpty) return [];
    final persons = await PersonService.instance.getPersonsMap();
    final facePersons = <String, String>{};
    for (final person in persons.values) {
      for (final faceID in await MLDataDB.instance.getFaceIDsForPerson(
        person.remoteID,
      )) {
        facePersons[faceID] = person.remoteID;
      }
    }
    final clusters = await MLDataDB.instance.getAllClusterIdToFaceIDs();
    for (final cluster in clusters.entries) {
      for (final faceID in cluster.value) {
        facePersons.putIfAbsent(faceID, () => "cluster:${cluster.key}");
      }
    }
    final times = {
      for (final file in files)
        if (file.uploadedFileID != null && file.creationTime != null)
          file.uploadedFileID!: file.creationTime!,
    };
    final timeKeys = times.keys.toList()..sort();
    final faceKeys = facePersons.keys.toList()..sort();
    final key = jsonEncode([
      _indexRevision,
      [
        for (final id in timeKeys) [id, times[id]],
      ],
      [
        for (final id in faceKeys) [id, facePersons[id]],
      ],
    ]);
    if (key != _matchKey) {
      _matches = List.unmodifiable(
        matchBodyDetections(indices, times, facePersons),
      );
      _matchKey = key;
    }
    return _matches;
  }

  Future<List<BodyGroup>> groups(List<EnteFile> files) async =>
      groupBodyMatches(await matches(files), {
        for (final f in files)
          if (f.uploadedFileID != null && f.creationTime != null)
            f.uploadedFileID!: f.creationTime!,
      });

  Future<List<(int, BodyDetection)>> groupMembers(String reference) async {
    final all = await indexes();
    final saved = <(int, BodyDetection)>[
      for (final entry in all.entries)
        for (final body in entry.value.detections)
          if (body.groupID == reference || body.bodyID == reference)
            (entry.key, body),
    ];
    if (saved.isNotEmpty) return saved;
    final candidates = await groups(
      await SearchService.instance.getAllFilesForSearch(),
    );
    final group = candidates.firstWhere((g) => g.id == reference);
    return [for (final m in group.matches) (m.fileID, m.detection)];
  }

  Future<void> _updateBody(
    EnteFile file,
    String bodyID,
    void Function(BodyDetection) update,
  ) async {
    final indexes = await this.indexes();
    final original = indexes[file.uploadedFileID];
    if (original == null) throw StateError("Body index is unavailable");
    final updated = BodyIndex.tryParse(
      jsonDecode(jsonEncode(original.toJson())),
    )!;
    update(updated.detections.firstWhere((d) => d.bodyID == bodyID));
    await BodyFeedbackService.instance.enqueue({
      file.uploadedFileID!: BodyFeedbackPatch.between(original, updated),
    });
    invalidateCaches();
    BodyFeedbackService.instance.scheduleSync();
  }

  Future<void> acceptGroup(
    PersonEntity person,
    String reference, {
    Map<int, BodyDetection>? suggestionSnapshot,
  }) async {
    final members = suggestionSnapshot != null && suggestionSnapshot.isNotEmpty
        ? [
            for (final entry in suggestionSnapshot.entries)
              (entry.key, entry.value),
          ]
        : await groupMembers(reference);
    final files = await FilesDB.instance.getFileIDToFileFromIDs(
      members.map((m) => m.$1).toList(),
    );
    final current = await PersonService.instance.getPerson(person.remoteID);
    if (current == null) throw StateError("Person is unavailable");
    final existing = current.data.manuallyAssigned.toSet();
    existing.addAll(
      (await MLDataDB.instance.getFileIdToClusterIDSet(person.remoteID)).keys,
    );
    final currentIndexes = await indexes();
    final bodyAddedManual = {
      for (final entry in currentIndexes.entries)
        if (entry.value.detections.any((body) {
          final decision = body.decisions[person.remoteID];
          return decision is Map &&
              decision["status"] == "accepted" &&
              decision["addedManual"] == true;
        }))
          entry.key,
    };
    await _updateGroup(files, members, (fileID, body) {
      body.bindReviewGroup(reference);
      final previous = body.decisions[person.remoteID];
      body.decisions[person.remoteID] = {
        "status": "accepted",
        "addedManual":
            !existing.contains(fileID) ||
            bodyAddedManual.contains(fileID) ||
            (previous is Map && previous["addedManual"] == true),
      };
    });
  }

  Future<void> rejectGroup(
    String personID,
    String reference, {
    Map<int, BodyDetection>? suggestionSnapshot,
  }) async {
    final members = suggestionSnapshot != null && suggestionSnapshot.isNotEmpty
        ? [
            for (final entry in suggestionSnapshot.entries)
              (entry.key, entry.value),
          ]
        : await groupMembers(reference);
    final files = await FilesDB.instance.getFileIDToFileFromIDs(
      members.map((m) => m.$1).toList(),
    );
    await _updateGroup(files, members, (_, body) {
      body.bindReviewGroup(reference);
      body.decisions[personID] = {"status": "rejected"};
    });
  }

  Future<void> _updateGroup(
    Map<int, EnteFile> files,
    List<(int, BodyDetection)> members,
    void Function(int, BodyDetection) update,
  ) async {
    final indexes = await this.indexes();
    final changed = <int, BodyIndex>{};
    for (final (id, detection) in members) {
      if (!files.containsKey(id)) continue;
      final original = indexes[id];
      if (original == null) throw StateError("Body index is unavailable");
      final next = changed.putIfAbsent(
        id,
        () => BodyIndex.tryParse(jsonDecode(jsonEncode(original.toJson())))!,
      );
      update(
        id,
        next.detections.firstWhere((d) => d.bodyID == detection.bodyID),
      );
    }
    await BodyFeedbackService.instance.enqueue({
      for (final entry in changed.entries)
        entry.key: BodyFeedbackPatch.between(indexes[entry.key]!, entry.value),
    });
    invalidateCaches();
    BodyFeedbackService.instance.scheduleSync();
  }

  Future<void> undoGroup(PersonEntity person, String reference) async {
    final members = await groupMembers(reference);
    final files = await FilesDB.instance.getFileIDToFileFromIDs(
      members.map((member) => member.$1).toList(),
    );
    await _updateGroup(
      files,
      members,
      (_, body) => body.decisions.remove(person.remoteID),
    );
  }

  Future<Map<String, List<EnteFile>>> splitGroup(
    String reference,
    Set<int> selected,
  ) async {
    final members = await groupMembers(reference);
    final candidates = await groups(
      await SearchService.instance.getAllFilesForSearch(),
    );
    String? suggestedPerson;
    for (final group in candidates) {
      if (group.id == reference) suggestedPerson = group.personID;
    }
    final selectedID = "body-group:${newClusterID()}";
    final result = <String, List<EnteFile>>{};
    for (final member in members) {
      final id = selected.contains(member.$1) ? selectedID : reference;
      final file = await FilesDB.instance.getAnyUploadedFile(member.$1);
      if (file == null) continue;
      await _updateBody(file, member.$2.bodyID, (body) {
        body.raw["groupID"] = id;
        if (selected.contains(member.$1)) {
          for (final entry in body.decisions.entries.toList()) {
            if (entry.value is Map && entry.value["status"] == "accepted") {
              body.decisions[entry.key] = {"status": "rejected"};
            }
          }
          if (suggestedPerson != null) {
            body.decisions[suggestedPerson] = {"status": "rejected"};
          }
        }
      });
      result.putIfAbsent(id, () => []).add(file);
    }
    return result;
  }

  Future<Map<String, List<EnteFile>>> breakUpGroup(String reference) async {
    final members = await groupMembers(reference);
    final files = await FilesDB.instance.getFileIDToFileFromIDs(
      members.map((m) => m.$1).toList(),
    );
    final matches = [
      for (final m in members)
        BodyMatch(
          m.$1,
          BodyDetection.fromJson(
            Map<String, dynamic>.from(m.$2.toJson())..remove("groupID"),
          ),
          "split",
          1,
          1,
        ),
    ];
    final partitions = groupBodyMatches(
      matches,
      {for (final f in files.values) f.uploadedFileID!: f.creationTime ?? 0},
      threshold: 0.9,
    )..sort((a, b) => b.matches.length.compareTo(a.matches.length));
    final result = <String, List<EnteFile>>{};
    for (int i = 0; i < partitions.length; i++) {
      final id = i == 0 ? reference : "body-group:${newClusterID()}";
      for (final match in partitions[i].matches) {
        final file = files[match.fileID]!;
        await _updateBody(
          file,
          match.detection.bodyID,
          (body) => body.raw["groupID"] = id,
        );
        result.putIfAbsent(id, () => []).add(file);
      }
    }
    return result;
  }

  Future<void> updateDecision(
    EnteFile file,
    String bodyID,
    String personID,
    Map<String, dynamic>? decision,
  ) async {
    await _updateBody(file, bodyID, (body) {
      if (decision == null) {
        body.decisions.remove(personID);
      } else {
        body.decisions[personID] = decision;
      }
    });
  }

  Future<void> accept(PersonEntity person, EnteFile file, String bodyID) async {
    final index = (await indexes())[file.uploadedFileID];
    if (index == null) throw StateError("Body index is unavailable");
    await acceptGroup(
      person,
      bodyID,
      suggestionSnapshot: {
        file.uploadedFileID!: index.detections.firstWhere(
          (d) => d.bodyID == bodyID,
        ),
      },
    );
  }

  Future<void> reject(String personID, EnteFile file, String bodyID) =>
      updateDecision(file, bodyID, personID, {"status": "rejected"});

  Future<void> undo(PersonEntity person, EnteFile file, String bodyID) async {
    await updateDecision(file, bodyID, person.remoteID, null);
  }

  Future<Map<int, Uint8List?>> crop(EnteFile file, String bodyID) async {
    final index = (await indexes())[file.uploadedFileID];
    if (index == null) return {};
    final members = await groupMembers(bodyID);
    final body = members.firstWhere((m) => m.$1 == file.uploadedFileID).$2;
    final crops = await FaceThumbnailGenerator.instance.generateFaceThumbnails(
      await getImagePathForML(file),
      [body.box],
    );
    return {file.uploadedFileID!: crops.first};
  }
}
