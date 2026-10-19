import "dart:convert";

import "package:computer/computer.dart";
import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/gateways/entity/models/type.dart";
import "package:photos/models/local_entity_data.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/entity_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/photos_contacts_service.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _EntityService entities;
  late _MLDataDB db;
  late PersonService service;

  setUpAll(() async {
    await Computer.shared().turnOn(workersCount: 1);
    SharedPreferences.setMockInitialValues({});
    ServiceLocator.instance.init(
      await SharedPreferences.getInstance(),
      Dio(),
      Dio(),
      Dio(),
      PackageInfo(
        appName: "Photos",
        packageName: "photos",
        version: "1.0.0",
        buildNumber: "1",
      ),
    );
  });
  tearDownAll(() => Computer.shared().turnOff());
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    entities = _EntityService();
    db = _MLDataDB();
    service = PersonService(
      entities,
      db,
      await SharedPreferences.getInstance(),
      contactsService: _ContactsService(),
      currentUserIDProvider: () => 1,
    );
  });

  test(
    "retires exact duplicate creations to the stable canonical person",
    () async {
      _seedDuplicates(entities, count: 3);

      await service.reconcileAutoUnnamedDuplicates();

      expect(entities.person("a")!.data.name, "");
      for (final id in ["b", "c"]) {
        final retired = entities.person(id)!;
        expect(retired.data.isHidden, isTrue);
        expect(retired.data.isUnnamed, isFalse);
        expect(retired.data.assigned, isEmpty);
        expect(retired.data.autoCreationFaceIDs, isNull);
        expect(entities.expectedVersions[id], 1);
      }
      expect(entities.deleteCount, 0);
      final writes = entities.addCount;
      await service.reconcileAutoUnnamedDuplicates();
      expect(entities.addCount, writes);
      expect(entities.deleteCount, 0);
    },
  );

  test(
    "sync retires duplicates and applies only the canonical mapping",
    () async {
      _seedDuplicates(entities, count: 2);
      db.seedMapping("a", {
        "cluster-a": {"face-1", "face-2"},
      });
      db.seedMapping("b", {
        "cluster-b": {"face-1", "face-2"},
      });
      db.seedMapping("stale", {
        "stale-cluster": {"stale-face"},
      });

      await service.sync();

      expect(entities.person("b")!.data.autoDuplicateOf, "a");
      expect(db.personMappings.keys, {"a"});
      expect(db.removedPersons, containsAll(["b", "stale"]));
      expect(db.removedFaceCaches, contains("b"));
      expect(db.faceToCluster, {"face-1": "cluster-a", "face-2": "cluster-a"});
      expect(db.clusterToPerson, {"cluster-a": "a"});
    },
  );

  test(
    "sync on another device removes mappings for an existing retirement",
    () async {
      entities.seed(_person("a", clusterID: "cluster-a"), id: "a");
      entities.seed(
        PersonData(name: "", isHidden: true, autoDuplicateOf: "a"),
        id: "b",
      );
      db.seedMapping("b", {
        "cluster-b": {"face-1", "face-2"},
      });
      entities.syncDiffCount = 1; // The remote retirement arrived in this diff.

      await service.sync();

      expect(db.personMappings.keys, {"a"});
      expect(db.personMappings["a"]!.keys, {"cluster-a"});
      expect(db.removedPersons, ["b"]);
      expect(db.removedFaceCaches, ["b"]);
    },
  );

  test(
    "deleting the canonical person allows a fresh unnamed creation",
    () async {
      _seedDuplicates(entities, count: 2);
      db.seedMapping("a", {
        "cluster-a": {"face-1", "face-2"},
      });
      db.seedMapping("b", {
        "cluster-b": {"face-1", "face-2"},
      });
      db.faceIDsByCluster["new-cluster"] = {"face-1", "face-2"};

      await service.sync();
      await service.deletePerson("a");
      final recreated = await service.addUnnamedPersonForClusterIfAbsent(
        "new-cluster",
      );

      expect(recreated, isNotNull);
      expect(recreated!.remoteID, isNot("a"));
      expect(recreated.remoteID, isNot("b"));
      expect(recreated.data.isUnnamed, isTrue);
      expect(recreated.data.isHidden, isFalse);
      expect(recreated.data.assigned.single.faces, {"face-1", "face-2"});
      expect(recreated.data.autoCreationFaceIDs, ["face-1", "face-2"]);
      expect(entities.person("b")!.data.isHidden, isTrue);
      expect(entities.person("b")!.data.assigned, isEmpty);
      expect(entities.person("b")!.data.autoDuplicateOf, "a");
    },
  );

  test("ordinary empty-diff sync retries a failed retirement", () async {
    _seedDuplicates(entities, count: 2);
    db.seedMapping("b", {
      "cluster-b": {"face-1", "face-2"},
    });
    entities.failWrites = true;
    await service.sync();
    expect(entities.person("b")!.data.autoDuplicateOf, isNull);

    entities.failWrites = false;
    await service.sync();

    expect(entities.person("b")!.data.autoDuplicateOf, "a");
    expect(db.personMappings.keys, {"a"});
    expect(entities.syncCalls, 2);
  });

  test("a concurrent rename wins the entity version conflict", () async {
    _seedDuplicates(entities, count: 2);
    entities.beforeWrite = (id) {
      if (id == "b") entities.rename("b", "Renamed during sync");
    };

    await service.reconcileAutoUnnamedDuplicates();

    expect(entities.person("b")!.data.name, "Renamed during sync");
    expect(entities.person("b")!.data.assigned, hasLength(1));
    expect(entities.expectedVersions["b"], 1);
    expect(entities.person("a")!.data.name, "");
    expect(entities.deleteCount, 0);
  });

  test("a failed retirement write leaves the active person intact", () async {
    _seedDuplicates(entities, count: 2);
    entities.failWrites = true;

    await service.reconcileAutoUnnamedDuplicates();

    expect(entities.person("b")!.data.isHidden, isFalse);
    expect(entities.person("b")!.data.isUnnamed, isTrue);
    expect(entities.person("b")!.data.assigned, hasLength(1));
    expect(entities.deleteCount, 0);
  });

  test(
    "canonical rename before the recheck prevents duplicate cleanup",
    () async {
      _seedDuplicates(entities, count: 2);
      entities.afterRead = (readCount) {
        if (readCount == 2) entities.rename("a", "Alex");
      };

      await service.reconcileAutoUnnamedDuplicates();

      expect(entities.person("a")!.data.name, "Alex");
      expect(entities.person("b")!.data.isHidden, isFalse);
      expect(entities.addCount, 0);
    },
  );

  test("body feedback for any group member protects every duplicate", () async {
    _seedDuplicates(entities, count: 3);
    db.indexes[42] = jsonEncode({
      "detections": [
        {
          "decisions": {"c": true},
        },
      ],
    });

    await service.reconcileAutoUnnamedDuplicates();

    expect(entities.addCount, 0);
    expect(entities.person("b")!.data.isHidden, isFalse);
    expect(entities.person("c")!.data.isHidden, isFalse);
  });

  test("malformed body feedback fails closed", () async {
    _seedDuplicates(entities, count: 2);
    db.indexes[42] = "not json";

    await service.reconcileAutoUnnamedDuplicates();

    expect(entities.addCount, 0);
    expect(entities.person("b")!.data.isHidden, isFalse);
  });

  test("generic person edits clear creation provenance", () async {
    _seedDuplicates(entities, count: 1);
    final original = entities.person("a")!;

    await service.updatePerson(
      original.copyWith(data: original.data.copyWith(name: "Alex")),
    );
    await service.updatePerson(
      original.copyWith(data: original.data.copyWith(name: "")),
    );

    expect(entities.person("a")!.data.name, "");
    expect(entities.person("a")!.data.isUnnamed, isTrue);
    expect(entities.person("a")!.data.autoCreationFaceIDs, isNull);
    expect(entities.expectedVersions["a"], isNull);
  });

  test(
    "body review claim clears provenance with a version precondition",
    () async {
      _seedDuplicates(entities, count: 1);

      await service.protectAutomaticPerson("a");

      expect(entities.person("a")!.data.autoCreationFaceIDs, isNull);
      expect(entities.person("a")!.data.assigned, hasLength(1));
      expect(entities.expectedVersions["a"], 1);
    },
  );

  test("body review cannot claim a retired duplicate", () async {
    _seedDuplicates(entities, count: 2);
    await service.reconcileAutoUnnamedDuplicates();

    await expectLater(service.protectAutomaticPerson("b"), throwsStateError);
    expect(entities.person("b")!.data.autoDuplicateOf, "a");
  });

  test("a version race leaves body feedback untouched", () async {
    _seedDuplicates(entities, count: 1);
    db.indexes[42] = jsonEncode({
      "detections": [
        {
          "decisions": {"a": true},
        },
      ],
    });
    final feedbackBefore = Map<int, String>.of(db.indexes);
    entities.beforeWrite = (id) {
      if (id == "a") entities.rename("a", "Renamed during review");
    };

    await expectLater(service.protectAutomaticPerson("a"), throwsStateError);

    expect(entities.person("a")!.data.name, "Renamed during review");
    expect(entities.person("a")!.data.autoCreationFaceIDs, [
      "face-1",
      "face-2",
    ]);
    expect(db.indexes, feedbackBefore);
    expect(entities.expectedVersions["a"], 1);
  });

  test("provenance JSON round trips and malformed values are ignored", () {
    final data = _person("a");
    final decoded = PersonData.fromJson(data.toJson());
    expect(decoded.autoCreationFaceIDs, ["face-1", "face-2"]);
    expect(
      PersonData.fromJson({"name": "", "autoDuplicateOf": "a"}).autoDuplicateOf,
      "a",
    );

    final legacy = PersonData.fromJson({"name": "", "isUnnamed": true});
    final malformed = PersonData.fromJson({
      "name": "",
      "isUnnamed": true,
      "autoCreationFaceIDs": ["face-1", 3],
    });
    expect(legacy.autoCreationFaceIDs, isNull);
    expect(malformed.autoCreationFaceIDs, isNull);
  });

  test("creation guard rejects overlapping faces across clusters", () async {
    entities.seed(_person("a", clusterID: "cluster-a"), id: "a");
    db.faceIDsByCluster["cluster-b"] = {"face-2", "face-3"};

    final created = await service.addUnnamedPersonForClusterIfAbsent(
      "cluster-b",
    );

    expect(created, isNull);
    expect(entities.addCount, 0);
    expect(entities.all, hasLength(1));
  });
}

void _seedDuplicates(_EntityService entities, {required int count}) {
  for (final id in ["a", "b", "c"].take(count)) {
    entities.seed(_person(id, clusterID: "cluster-$id"), id: id);
  }
}

PersonData _person(String id, {String? clusterID}) => PersonData(
  name: "",
  isUnnamed: true,
  autoCreationFaceIDs: const ["face-1", "face-2"],
  assigned: [
    ClusterInfo(id: clusterID ?? "cluster-$id", faces: {"face-1", "face-2"}),
  ],
);

class _EntityService implements EntityService {
  final records = <String, LocalEntityData>{};
  final expectedVersions = <String, int?>{};
  int addCount = 0;
  int deleteCount = 0;
  int _nextVersion = 2;
  int _readCount = 0;
  int syncCalls = 0;
  int syncDiffCount = 0;
  bool failWrites = false;
  void Function(String id)? beforeWrite;
  void Function(int readCount)? afterRead;

  Iterable<LocalEntityData> get all => records.values;

  PersonEntity? person(String id) {
    final record = records[id];
    return record == null
        ? null
        : PersonEntity(id, PersonData.fromJson(jsonDecode(record.data)));
  }

  void seed(PersonData data, {required String id}) {
    records[id] = LocalEntityData(
      id: id,
      type: EntityType.cgroup,
      data: jsonEncode(data.toJson()),
      ownerID: 1,
      updatedAt: 1,
    );
  }

  void rename(String id, String name) {
    final old = records[id]!;
    final data = PersonData.fromJson(jsonDecode(old.data));
    records[id] = LocalEntityData(
      id: id,
      type: EntityType.cgroup,
      data: jsonEncode(data.copyWith(name: name).toJson()),
      ownerID: old.ownerID,
      updatedAt: _nextVersion++,
    );
  }

  @override
  int lastSyncTime(EntityType type) => 0;

  @override
  Future<int> syncEntity(EntityType type) async {
    syncCalls++;
    return syncDiffCount;
  }

  @override
  Future<List<LocalEntityData>> getEntities(EntityType type) async {
    afterRead?.call(++_readCount);
    return records.values.toList();
  }

  @override
  Future<LocalEntityData?> getEntity(EntityType type, String id) async =>
      records[id];

  @override
  Future<void> deleteEntry(String id) async {
    deleteCount++;
    records.remove(id);
  }

  @override
  Future<LocalEntityData> addOrUpdate(
    EntityType type,
    Map<String, dynamic> jsonMap, {
    String? id,
    bool addWithCustomID = false,
    int? expectedUpdatedAt,
  }) async {
    addCount++;
    final entityID = id ?? "generated-$addCount";
    expectedVersions[entityID] = expectedUpdatedAt;
    beforeWrite?.call(entityID);
    if (failWrites) throw StateError("offline");
    final old = records[entityID];
    if (expectedUpdatedAt != null && old?.updatedAt != expectedUpdatedAt) {
      throw StateError("entity version changed");
    }
    final updated = LocalEntityData(
      id: entityID,
      type: type,
      data: jsonEncode(jsonMap),
      ownerID: old?.ownerID ?? 1,
      updatedAt: _nextVersion++,
    );
    records[entityID] = updated;
    return updated;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MLDataDB implements IMLDataDB<int> {
  final indexes = <int, String>{};
  final faceIDsByCluster = <String, Set<String>>{};
  final personMappings = <String, Map<String, Set<String>>>{};
  final removedPersons = <String>[];
  final removedFaceCaches = <String>[];
  final faceToCluster = <String, String>{};
  final clusterToPerson = <String, String>{};

  void seedMapping(String personID, Map<String, Set<String>> clusters) {
    personMappings[personID] = clusters;
  }

  @override
  Future<Map<int, String>> bodyIndexes({int minimumVersion = 1}) async =>
      indexes;

  @override
  Future<Iterable<String>> getFaceIDsForCluster(String clusterID) async =>
      faceIDsByCluster[clusterID] ?? {"face-1", "face-2"};

  @override
  Future<void> assignClusterToPerson({
    required String personID,
    required String clusterID,
  }) async {
    personMappings.putIfAbsent(personID, () => {})[clusterID] =
        faceIDsByCluster[clusterID] ?? {"face-1", "face-2"};
  }

  @override
  Future<Map<String, Map<String, Set<String>>>>
  getPersonToClusterIdToFaceIds() async => personMappings;

  @override
  Future<Map<String, Set<String>>> getPersonToClusterIDs() async => {
    for (final entry in personMappings.entries)
      entry.key: entry.value.keys.toSet(),
  };

  @override
  Future<void> updateFaceIdToClusterId(Map<String, String> updates) async {
    faceToCluster.addAll(updates);
  }

  @override
  Future<void> bulkAssignClusterToPersonID(
    Map<String, String> assignments,
  ) async {
    clusterToPerson.addAll(assignments);
    for (final entry in assignments.entries) {
      personMappings.putIfAbsent(entry.value, () => {})[entry.key] =
          faceIDsByCluster[entry.key] ?? {"face-1", "face-2"};
    }
  }

  @override
  Future<void> removePerson(String personID) async {
    removedPersons.add(personID);
    personMappings.remove(personID);
  }

  @override
  Future<void> removeFaceIdCachedForPersonOrCluster(
    String personOrClusterID,
  ) async {
    removedFaceCaches.add(personOrClusterID);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ContactsService implements PhotosContactsService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
