import "dart:convert";

import "package:computer/computer.dart";
import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/events/people_changed_event.dart";
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
    final preferences = await SharedPreferences.getInstance();
    ServiceLocator.instance.init(
      preferences,
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
    "deletion refreshes unlinked persons before notifying listeners",
    () async {
      entities.seed(PersonData(name: "Alex"));
      expect((await service.getPersonsMap()).keys, ["person"]);
      expect(service.getCachedPerson("person"), isNotNull);
      final eventPersons = Bus.instance.on<PeopleChangedEvent>().first.then(
        (_) => service.getPersonsMap(),
      );

      await service.deletePerson("person");

      expect(await eventPersons, isEmpty);
      expect(await service.getPersons(), isEmpty);
      expect(service.getCachedPerson("person"), isNull);
      expect(db.removedPersons, ["person"]);
    },
  );

  test("deletion also clears a user link without an email", () async {
    entities.seed(PersonData(name: "Alex", userID: 7));
    await service.getPersons();
    expect(service.getCachedPersonForUser(7, ""), isNotNull);

    await service.deletePerson("person");

    expect(service.getCachedPersonForUser(7, ""), isNull);
  });

  test("repeated lookup returns an existing active unnamed person", () async {
    entities.seed(
      PersonData(
        name: "",
        isUnnamed: true,
        assigned: [
          ClusterInfo(id: "cluster", faces: {"1_face"}),
        ],
      ),
    );

    final first = await service.addUnnamedPersonForClusterIfAbsent("cluster");
    final second = await service.addUnnamedPersonForClusterIfAbsent("cluster");

    expect(first?.remoteID, "person");
    expect(second?.remoteID, first?.remoteID);
    expect(entities.addCount, 0);
  });

  test("first create is reused by the repeated local pass", () async {
    db.faceIDsByCluster["cluster"] = {"1_face"};

    final first = await service.addUnnamedPersonForClusterIfAbsent("cluster");
    final second = await service.addUnnamedPersonForClusterIfAbsent("cluster");

    expect(first?.data.isUnnamed, isTrue);
    expect(second?.remoteID, first?.remoteID);
    expect(entities.addCount, 1);
  });

  test(
    "deleted unnamed person can be recreated with a fresh entity ID",
    () async {
      db.faceIDsByCluster["cluster"] = {"1_face"};

      final first = await service.addUnnamedPersonForClusterIfAbsent("cluster");
      await service.deletePerson(first!.remoteID);
      final recreated = await service.addUnnamedPersonForClusterIfAbsent(
        "cluster",
      );

      expect(recreated, isNotNull);
      expect(recreated!.remoteID, isNot(first.remoteID));
      expect(entities.addCount, 2);
      expect(entities.addWithCustomIDCalls, [false, false]);
    },
  );

  test("named cluster assignment blocks unnamed creation", () async {
    entities.seed(
      PersonData(
        name: "Alex",
        assigned: [
          ClusterInfo(id: "named-cluster", faces: {"1_face"}),
        ],
      ),
    );
    final namedResult = await service.addUnnamedPersonForClusterIfAbsent(
      "named-cluster",
    );
    expect(namedResult, isNull);
    expect(entities.addCount, 0);
  });

  test("hidden unnamed cluster assignment blocks unnamed creation", () async {
    entities.seed(
      PersonData(
        name: "",
        isHidden: true,
        isUnnamed: true,
        assigned: [
          ClusterInfo(id: "hidden-cluster", faces: {"2_face"}),
        ],
      ),
    );
    final hiddenResult = await service.addUnnamedPersonForClusterIfAbsent(
      "hidden-cluster",
    );
    expect(hiddenResult, isNull);
    expect(entities.addCount, 0);
  });

  test(
    "mapping reset keeps the name and refreshes cached assignments",
    () async {
      entities.seed(
        PersonData(
          name: "Alex",
          assigned: [
            ClusterInfo(id: "cluster", faces: {"1_face"}),
          ],
        ),
      );
      await service.getPersons();

      await service.deletePerson("person", onlyMapping: true);

      final remaining = (await service.getPersons()).single;
      expect(remaining.data.name, "Alex");
      expect(remaining.data.assigned, isEmpty);
      expect(service.getCachedPerson("person")!.data.assigned, isEmpty);
    },
  );

  test(
    "failed remote deletion retains the cached person and mappings",
    () async {
      entities.seed(PersonData(name: "Alex"));
      await service.getPersons();
      entities.failDelete = true;

      await expectLater(service.deletePerson("person"), throwsStateError);

      expect((await service.getPersons()).single.data.name, "Alex");
      expect(db.removedPersons, isEmpty);
    },
  );
}

class _EntityService implements EntityService {
  LocalEntityData? entity;
  bool failDelete = false;
  int addCount = 0;
  int _nextGeneratedID = 0;
  final addWithCustomIDCalls = <bool>[];

  void seed(PersonData data, {String id = "person"}) {
    entity = LocalEntityData(
      id: id,
      type: EntityType.cgroup,
      data: jsonEncode(data.toJson()),
      ownerID: 1,
      updatedAt: 1,
    );
  }

  @override
  int lastSyncTime(EntityType type) => 0;

  @override
  Future<List<LocalEntityData>> getEntities(EntityType type) async => [?entity];

  @override
  Future<LocalEntityData?> getEntity(EntityType type, String id) async =>
      entity;

  @override
  Future<void> deleteEntry(String id) async {
    if (failDelete) throw StateError("offline");
    entity = null;
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
    addWithCustomIDCalls.add(addWithCustomID);
    seed(
      PersonData.fromJson(jsonMap),
      id: id ?? "generated-${_nextGeneratedID++}",
    );
    return entity!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MLDataDB implements IMLDataDB<int> {
  final removedPersons = <String>[];
  final personToClusterIDs = <String, Map<String, Set<String>>>{};
  final faceIDsByCluster = <String, Set<String>>{};

  @override
  Future<Iterable<String>> getFaceIDsForCluster(String clusterID) async =>
      faceIDsByCluster[clusterID] ?? {"1_face"};

  @override
  Future<void> assignClusterToPerson({
    required String personID,
    required String clusterID,
  }) async {
    personToClusterIDs.putIfAbsent(personID, () => {})[clusterID] =
        faceIDsByCluster[clusterID] ?? {"1_face"};
  }

  @override
  Future<Map<String, Map<String, Set<String>>>>
  getPersonToClusterIdToFaceIds() async => personToClusterIDs;

  @override
  Future<void> removePerson(String personID) async {
    removedPersons.add(personID);
    personToClusterIDs.remove(personID);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ContactsService implements PhotosContactsService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
