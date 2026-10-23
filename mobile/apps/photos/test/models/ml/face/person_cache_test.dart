import "dart:convert";

import "package:computer/computer.dart";
import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/gateways/entity/models/type.dart";
import "package:photos/models/local_entity_data.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/services/entity_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/photos_contacts_service.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _EntityService entities;
  late _MLDataDB db;
  late PersonService service;

  setUpAll(() => Computer.shared().turnOn(workersCount: 1));
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
  test(
    "queued manual assignment retries against the updated person version",
    () async {
      entities.seed(PersonData(name: "Alex", manuallyAssigned: [1]));
      entities.conflictUpdate = PersonData(
        name: "Updated elsewhere",
        manuallyAssigned: [1, 9],
      );
      await service.setManualFileAssignmentForSession(
        "person",
        7,
        true,
        () => true,
      );
      final person = await service.getPerson("person");
      expect(person!.data.name, "Updated elsewhere");
      expect(person.data.manuallyAssigned.toSet(), {1, 7, 9});
      expect(entities.expectedVersions, [1, 2]);
    },
  );

  test(
    "queued manual removal preserves other tags and rejects a stale session",
    () async {
      entities.seed(PersonData(name: "Alex", manuallyAssigned: [7, 9]));
      await service.setManualFileAssignmentForSession(
        "person",
        7,
        false,
        () => true,
      );
      expect((await service.getPerson("person"))!.data.manuallyAssigned, [9]);
      await expectLater(
        service.setManualFileAssignmentForSession(
          "person",
          8,
          true,
          () => false,
        ),
        throwsStateError,
      );
      expect((await service.getPerson("person"))!.data.manuallyAssigned, [9]);
    },
  );
}

class _EntityService implements EntityService {
  LocalEntityData? entity;
  bool failDelete = false;
  PersonData? conflictUpdate;
  bool conflictRaised = false;
  final expectedVersions = <int?>[];

  void seed(PersonData data) {
    entity = LocalEntityData(
      id: "person",
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
    seed(PersonData.fromJson(jsonMap));
    return entity!;
  }

  @override
  Future<LocalEntityData> addOrUpdateForSession(
    EntityType type,
    Map<String, dynamic> data, {
    required String id,
    required bool Function() isCurrentSession,
    int? expectedUpdatedAt,
  }) async {
    if (!isCurrentSession()) throw StateError("stale session");
    expectedVersions.add(expectedUpdatedAt);
    if (conflictUpdate != null && !conflictRaised) {
      conflictRaised = true;
      final options = RequestOptions(path: "/user-entities");
      throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 409),
      );
    }
    seed(PersonData.fromJson(data));
    return entity!;
  }

  @override
  Future<int> syncEntity(EntityType type) async {
    if (conflictUpdate == null) return 0;
    seed(conflictUpdate!);
    entity = LocalEntityData(
      id: entity!.id,
      type: entity!.type,
      data: entity!.data,
      ownerID: entity!.ownerID,
      updatedAt: 2,
    );
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MLDataDB implements IMLDataDB<int> {
  final removedPersons = <String>[];

  @override
  Future<void> removePerson(String personID) async {
    removedPersons.add(personID);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ContactsService implements PhotosContactsService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
