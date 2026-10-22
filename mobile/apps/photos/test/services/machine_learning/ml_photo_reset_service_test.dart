import "dart:async";
import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/face/detection.dart";
import "package:photos/models/ml/face/face.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/services/filedata/filedata_service.dart";
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/services/filedata/model/response.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/ml_photo_reset_service.dart";
import "package:photos/utils/face/face_thumbnail_cache.dart"
    show checkUsedFaceIDForPersonOrClusterId, putFaceIdCachedForPersonOrCluster;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    "full reset deletes emptied persons and preserves remaining links",
    () async {
      final db = _MemoryMLDB()
        ..faces[10] = [_face(10)]
        ..faces[12] = [_face(12)]
        ..faces[11] = [_face(11)];
      final persons = _MemoryPersons([
        _person(
          "emptied",
          clusters: {
            "cluster-12": {_faceID(12)},
          },
        ),
        _person(
          "remaining-cluster",
          clusters: {
            "cluster-shared": {_faceID(10), _faceID(11)},
          },
        ),
        _person("remaining-manual", manual: [11]),
        _person(
          "body-person",
          clusters: {
            "cluster-body-face": {_faceID(10)},
          },
        ),
      ]);
      db.clusterByFace[_faceID(10)] = "cluster-shared";
      db.clusterByFace[_faceID(11)] = "cluster-shared";
      db.clusterByFace[_faceID(12)] = "cluster-12";
      db.body[99] = jsonEncode(_bodyIndex(acceptedPerson: "body-person"));
      final metadata = _MemoryMetadata({
        10: {"face": 1, "future": "keep"},
        12: {"face": 1},
      });

      await _service(db, persons, metadata).reset([_file(10), _file(12)]);

      expect(persons.deleted, contains("emptied"));
      expect(persons.deleted, isNot(contains("remaining-cluster")));
      expect(persons.deleted, isNot(contains("remaining-manual")));
      expect(persons.deleted, isNot(contains("body-person")));
      expect(persons.items["remaining-cluster"]!.data.assigned.single.faces, {
        _faceID(11),
      });
      expect(persons.items["remaining-manual"]!.data.manuallyAssigned, [11]);
      expect(metadata.data[10], {"future": "keep"});
      expect(db.deletedFaceFiles, [
        [10, 12],
      ]);
      expect(db.faces[11], hasLength(1));
    },
  );

  test(
    "full reset deletes a person whose accepted body binding was cleared",
    () async {
      final db = _MemoryMLDB()
        ..body[10] = jsonEncode(_bodyIndex(acceptedPerson: "body-only"));
      final persons = _MemoryPersons([_person("body-only")]);
      final metadata = _MemoryMetadata({
        10: {"body": _bodyIndex(acceptedPerson: "body-only")},
      });

      await _service(db, persons, metadata).reset([_file(10)]);

      expect(persons.deleted, ["body-only"]);
      expect(db.deletedBodyFiles, [
        [10],
      ]);
      expect(metadata.data[10], isEmpty);
    },
  );

  test(
    "full reset clears only selected face indexes and preserves unknown metadata",
    () async {
      final db = _MemoryMLDB()
        ..faces[10] = [_face(10)]
        ..faces[11] = [_face(11)];
      final metadata = _MemoryMetadata({
        10: {
          "face": {
            "faces": [1],
          },
          "clip": {
            "embedding": [2],
          },
          "body": {"detection": 1},
          "future": {"keep": true},
        },
        11: {
          "face": {
            "faces": [2],
          },
          "clip": {
            "embedding": [3],
          },
          "future": 4,
        },
      });

      await _service(db, _MemoryPersons([]), metadata).reset([_file(10)]);

      expect(db.deletedFaceFiles, [
        [10],
      ]);
      expect(metadata.data[10], {
        "future": {"keep": true},
      });
      expect(metadata.data[11], {
        "face": {
          "faces": [2],
        },
        "clip": {
          "embedding": [3],
        },
        "future": 4,
      });
    },
  );

  test(
    "binding reset keeps face indexes and clears selected cluster feedback",
    () async {
      final db = _MemoryMLDB()
        ..faces[10] = [_face(10)]
        ..clusterByFace[_faceID(10)] = "cluster-10"
        ..rejected["reviewer"] = {"cluster-10"};
      final persons = _MemoryPersons([
        _person(
          "named",
          clusters: {
            "cluster-10": {_faceID(10)},
          },
        ),
      ]);
      final metadata = _MemoryMetadata({
        10: {
          "face": {
            "faces": [1],
          },
          "clip": {
            "embedding": [2],
          },
          "future": 7,
        },
      });

      await _service(db, persons, metadata).resetPersonBindings([_file(10)]);

      expect(db.deletedFaceFiles, isEmpty);
      expect(db.clusterByFace, {_faceID(10): "cluster-10"});
      expect(db.removedClusterAssignments, {("named", "cluster-10")});
      expect(db.invalidatedFaceCaches, containsAll(["named", "cluster-10"]));
      expect(persons.deleted, ["named"]);
      expect(persons.items.containsKey("named"), isFalse);
      expect(db.rejected, isEmpty);
      expect(metadata.data[10], {
        "face": {
          "faces": [1],
        },
        "clip": {
          "embedding": [2],
        },
        "future": 7,
      });
    },
  );

  test(
    "ML resets evict warmed mappings when DB rows are already gone",
    () async {
      for (final fullReset in [false, true]) {
        final fileID = fullReset ? 11 : 10;
        final personID = "named-$fileID";
        final clusterID = "cluster-$fileID";
        final db = _MemoryMLDB()
          ..faces[fileID] = [_face(fileID)]
          ..clusterByFace[_faceID(fileID)] = clusterID;
        final persons = _MemoryPersons([
          _person(
            personID,
            clusters: {
              clusterID: {_faceID(fileID)},
            },
          ),
        ]);
        await putFaceIdCachedForPersonOrCluster(
          personID,
          "old-person-face-$fileID",
          db: db,
        );
        await putFaceIdCachedForPersonOrCluster(
          clusterID,
          "old-cluster-face-$fileID",
          db: db,
        );

        // The mapping rows can be removed independently while the process LRU
        // still serves the previous avatar face IDs.
        await db.removeFaceIdCachedForPersonOrCluster(personID);
        await db.removeFaceIdCachedForPersonOrCluster(clusterID);
        expect(
          await checkUsedFaceIDForPersonOrClusterId(personID, db: db),
          "old-person-face-$fileID",
        );
        expect(
          await checkUsedFaceIDForPersonOrClusterId(clusterID, db: db),
          "old-cluster-face-$fileID",
        );

        final service = _service(
          db,
          persons,
          _MemoryMetadata({
            fileID: {"face": 1},
          }),
        );
        if (fullReset) {
          await service.reset([_file(fileID)]);
        } else {
          await service.resetPersonBindings([_file(fileID)]);
        }

        expect(
          await checkUsedFaceIDForPersonOrClusterId(personID, db: db),
          isNull,
        );
        expect(
          await checkUsedFaceIDForPersonOrClusterId(clusterID, db: db),
          isNull,
        );
      }
    },
  );

  test(
    "binding reset writes cleared body decisions back to the local index",
    () async {
      final rawBody = _bodyIndex(acceptedPerson: "person-1");
      final db = _MemoryMLDB()..body[10] = jsonEncode(rawBody);
      final metadata = _MemoryMetadata({
        10: {"body": rawBody},
      });

      await _service(
        db,
        _MemoryPersons([]),
        metadata,
      ).resetPersonBindings([_file(10)]);

      final local = jsonDecode(db.body[10]!) as Map<String, dynamic>;
      expect((local["detections"] as List).single["decisions"], isEmpty);
      final remote = metadata.data[10]!["body"] as Map<String, dynamic>;
      expect((remote["detections"] as List).single["decisions"], isEmpty);
    },
  );

  test(
    "binding reset clears stale local body decisions and deletes its empty body-only person",
    () async {
      final remoteBody = _bodyIndex();
      final localBody = _bodyIndex(acceptedPerson: "stale-body-only");
      final db = _MemoryMLDB()..body[10] = jsonEncode(localBody);
      final metadata = _MemoryMetadata({
        10: {"body": remoteBody},
      });
      final persons = _MemoryPersons([_person("stale-body-only")]);

      await _service(db, persons, metadata).resetPersonBindings([_file(10)]);

      final local = jsonDecode(db.body[10]!) as Map<String, dynamic>;
      expect((local["detections"] as List).single["decisions"], isEmpty);
      expect((metadata.data[10]!["body"] as Map)["detections"], isNotEmpty);
      expect(persons.deleted, ["stale-body-only"]);
    },
  );

  test(
    "a failed metadata fetch leaves that photo's face and person bindings intact",
    () async {
      final db = _MemoryMLDB()
        ..faces[10] = [_face(10)]
        ..faces[11] = [_face(11)]
        ..clusterByFace.addAll({
          _faceID(10): "cluster-10",
          _faceID(11): "cluster-11",
        });
      final persons = _MemoryPersons([
        _person(
          "first",
          clusters: {
            "cluster-10": {_faceID(10)},
          },
        ),
        _person(
          "second",
          clusters: {
            "cluster-11": {_faceID(11)},
          },
        ),
      ]);
      final metadata = _MemoryMetadata({
        10: {"face": 1},
        11: {"face": 2},
      })..fetchErrors = {11};

      final result = await _service(
        db,
        persons,
        metadata,
      ).reset([_file(10), _file(11)]);

      expect(result.failedFileIDs, [11]);
      expect(db.deletedFaceFiles, [
        [10],
      ]);
      expect(persons.items["second"]!.data.assigned.single.faces, {
        _faceID(11),
      });
      expect(db.clusterByFace[_faceID(11)], "cluster-11");
    },
  );

  test(
    "a failed binding metadata fetch leaves that photo's face and person bindings intact",
    () async {
      final db = _MemoryMLDB()
        ..faces[10] = [_face(10)]
        ..faces[11] = [_face(11)]
        ..clusterByFace.addAll({
          _faceID(10): "cluster-10",
          _faceID(11): "cluster-11",
        });
      final persons = _MemoryPersons([
        _person(
          "first",
          clusters: {
            "cluster-10": {_faceID(10)},
          },
        ),
        _person(
          "second",
          clusters: {
            "cluster-11": {_faceID(11)},
          },
        ),
      ]);
      final metadata = _MemoryMetadata({
        10: {"face": 1},
        11: {"face": 2},
      })..fetchErrors = {11};

      final result = await _service(
        db,
        persons,
        metadata,
      ).resetPersonBindings([_file(10), _file(11)]);

      expect(result.failedFileIDs, [11]);
      expect(db.faces[11], hasLength(1));
      expect(persons.items["second"]!.data.assigned.single.faces, {
        _faceID(11),
      });
      expect(db.clusterByFace[_faceID(11)], "cluster-11");
      expect(persons.deleted, isNot(contains("second")));
    },
  );

  test(
    "selected metadata reads batch at 200 and writes run at most four at once",
    () async {
      final files = List.generate(201, (index) => _file(index + 1));
      final metadata = _MemoryMetadata({
        for (var i = 1; i <= 201; i++) i: {"face": i},
      });
      await _service(_MemoryMLDB(), _MemoryPersons([]), metadata).reset(files);

      expect(metadata.readBatchSizes, [200, 1]);
      expect(metadata.maxConcurrentWrites, lessThanOrEqualTo(4));
      expect(metadata.changedWrites, hasLength(201));
      expect(metadata.changedWrites.toSet(), hasLength(201));
    },
  );

  test(
    "a metadata batch exception leaves every photo in that batch unchanged",
    () async {
      final db = _MemoryMLDB()
        ..faces[10] = [_face(10)]
        ..faces[11] = [_face(11)];
      final metadata = _MemoryMetadata({
        10: {"face": 10},
        11: {"face": 11},
      })..throwOnFetchContaining = {10};

      final result = await _service(
        db,
        _MemoryPersons([]),
        metadata,
      ).reset([_file(10), _file(11)]);

      expect(result.failedFileIDs, containsAll([10, 11]));
      expect(db.deletedFaceFiles, isEmpty);
      expect(db.faces.keys, containsAll([10, 11]));
      expect(metadata.data[10], {"face": 10});
      expect(metadata.data[11], {"face": 11});
    },
  );

  test("binding reset of unsupported body data fails safely", () async {
    final db = _MemoryMLDB()..faces[10] = [_face(10)];
    final metadata = _MemoryMetadata({
      10: {
        "body": {"version": 999, "future": true},
      },
    });

    final result = await _service(
      db,
      _MemoryPersons([]),
      metadata,
    ).resetPersonBindings([_file(10)]);

    expect(result.failedFileIDs, [10]);
    expect(db.deletedFaceFiles, isEmpty);
    expect(db.faces[10], hasLength(1));
    expect(metadata.data[10], {
      "body": {"version": 999, "future": true},
    });
  });
}

MLPhotoResetService _service(
  _MemoryMLDB db,
  _MemoryPersons persons,
  _MemoryMetadata metadata,
) => MLPhotoResetService(
  db: db,
  persons: persons,
  metadata: metadata,
  invalidateBodyCaches: () {},
);

EnteFile _file(int id) => EnteFile()
  ..uploadedFileID = id
  ..ownerID = null;

Face _face(int fileID) =>
    Face(_faceID(fileID), fileID, const [1.0], 0.9, Detection.empty(), 1.0);

String _faceID(int fileID) => "${fileID}_0_0_0_0";

PersonEntity _person(
  String id, {
  Map<String, Set<String>> clusters = const {},
  List<int> manual = const [],
}) => PersonEntity(
  id,
  PersonData(
    name: id,
    assigned: clusters.entries
        .map((e) => ClusterInfo(id: e.key, faces: e.value))
        .toList(),
    manuallyAssigned: manual,
  ),
);

Map<String, dynamic> _bodyIndex({String? acceptedPerson}) => {
  "version": 1,
  "model": "osnet-ain-x1.0-msmt17-v1",
  "width": 100,
  "height": 100,
  "detections": [
    {
      "bodyID": "body:detection-1",
      "box": {"x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5},
      "score": 0.9,
      "embedding": List<double>.filled(512, 1 / 512),
      "decisions": acceptedPerson == null
          ? <String, dynamic>{}
          : {
              acceptedPerson: {"status": "accepted"},
            },
    },
  ],
};

class _MemoryPersons implements PersonService {
  final Map<String, PersonEntity> items;
  final List<String> deleted = [];
  _MemoryPersons(Iterable<PersonEntity> persons)
    : items = {for (final person in persons) person.remoteID: person};

  @override
  Future<List<PersonEntity>> getPersons() async => items.values.toList();

  @override
  Future<void> updatePerson(PersonEntity person) async =>
      items[person.remoteID] = person;

  @override
  Future<void> deletePerson(String personID, {bool onlyMapping = false}) async {
    deleted.add(personID);
    items.remove(personID);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryMLDB implements IMLDataDB<int> {
  final Map<int, List<Face>> faces = {};
  final Map<int, String> body = {};
  final Map<String, String> clusterByFace = {};
  final Map<String, Set<String>> rejected = {};
  final Map<String, String> cachedFaceIDs = {};
  final Set<(String, String)> removedClusterAssignments = {};
  final Set<String> invalidatedFaceCaches = {};
  final List<List<int>> deletedFaceFiles = [];
  final List<List<int>> deletedClipFiles = [];
  final List<List<int>> deletedBodyFiles = [];

  @override
  Future<List<Face>?> getFacesForGivenFileID(int fileUploadID) async =>
      faces[fileUploadID];
  @override
  Future<Map<String, String?>> getFaceIdsToClusterIds(
    Iterable<String> faceIds,
  ) async => {for (final id in faceIds) id: clusterByFace[id]};
  @override
  Future<Map<String, Set<String>>> getPersonToRejectedSuggestions() async => {
    for (final entry in rejected.entries) entry.key: Set.of(entry.value),
  };
  @override
  Future<void> removeNotPersonFeedback({
    required String personID,
    required String clusterID,
  }) async {
    rejected[personID]?.remove(clusterID);
    if (rejected[personID]?.isEmpty ?? false) rejected.remove(personID);
  }

  @override
  Future<void> removeClusterToPerson({
    required String personID,
    required String clusterID,
  }) async {
    removedClusterAssignments.add((personID, clusterID));
  }

  @override
  Future<void> removeFaceIdToClusterId(
    Map<String, String> faceIDToClusterID,
  ) async {
    for (final faceID in faceIDToClusterID.keys) {
      clusterByFace.remove(faceID);
    }
  }

  @override
  Future<void> removeFaceIdCachedForPersonOrCluster(
    String personOrClusterID,
  ) async {
    invalidatedFaceCaches.add(personOrClusterID);
    cachedFaceIDs.remove(personOrClusterID);
  }

  @override
  Future<String?> getFaceIdUsedForPersonOrCluster(
    String personOrClusterId,
  ) async => cachedFaceIDs[personOrClusterId];

  @override
  Future<void> putFaceIdCachedForPersonOrCluster(
    String personOrClusterId,
    String faceID,
  ) async => cachedFaceIDs[personOrClusterId] = faceID;

  @override
  Future<void> deleteClusterSummary(String clusterID) async {}
  @override
  Future<void> deleteFaceIndexForFiles(List<int> fileIDs) async {
    deletedFaceFiles.add(List.of(fileIDs));
    for (final id in fileIDs) {
      faces.remove(id);
    }
  }

  @override
  Future<void> deleteClipEmbeddings(List<int> fileIDs) async =>
      deletedClipFiles.add(List.of(fileIDs));
  @override
  Future<void> deleteBodyIndexes(List<int> fileIDs) async {
    deletedBodyFiles.add(List.of(fileIDs));
    for (final id in fileIDs) {
      body.remove(id);
    }
  }

  @override
  Future<void> putBodyIndex(int fileID, String data, int version) async =>
      body[fileID] = data;
  @override
  Future<Map<int, String>> bodyIndexes({int minimumVersion = 1}) async =>
      Map.unmodifiable(body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryMetadata implements FileDataService {
  final Map<int, Map<String, dynamic>> data;
  final List<int> readBatchSizes = [];
  Set<int> fetchErrors = {};
  Set<int> throwOnFetchContaining = {};
  int concurrentWrites = 0;
  int maxConcurrentWrites = 0;
  final List<int> changedWrites = [];

  _MemoryMetadata(this.data);

  @override
  Future<FileDataResponse> getFilesData(
    Set<int> ids, {
    DataType type = DataType.mlData,
  }) async {
    readBatchSizes.add(ids.length);
    if (ids.any(throwOnFetchContaining.contains)) {
      throw StateError("Injected metadata batch fetch failure");
    }
    return FileDataResponse(
      {
        for (final id in ids)
          if (data.containsKey(id))
            id: FileDataEntity.fromRemote(
              id,
              "mldata",
              jsonDecode(jsonEncode(data[id])) as Map<String, dynamic>,
            )..updatedAt = 1,
      },
      fetchErrorFileIDs: ids.intersection(fetchErrors),
      pendingIndexFileIDs: {},
    );
  }

  @override
  Future<FileDataEntity> updateFileDataAllowingPartialMetadata(
    EnteFile file,
    FutureOr<bool> Function(FileDataEntity) update, {
    DataType type = DataType.mlData,
    FileDataEntity? initialData,
  }) async {
    final id = file.uploadedFileID!;
    concurrentWrites++;
    if (concurrentWrites > maxConcurrentWrites) {
      maxConcurrentWrites = concurrentWrites;
    }
    try {
      await Future<void>.delayed(Duration.zero);
      final latest = FileDataEntity.fromRemote(
        id,
        "mldata",
        jsonDecode(jsonEncode(initialData?.remoteRawData ?? data[id] ?? {}))
            as Map<String, dynamic>,
      )..updatedAt = initialData?.updatedAt ?? 1;
      if (await update(latest)) {
        data[id] =
            jsonDecode(jsonEncode(latest.remoteRawData))
                as Map<String, dynamic>;
        changedWrites.add(id);
      }
      return latest;
    } finally {
      concurrentWrites--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
