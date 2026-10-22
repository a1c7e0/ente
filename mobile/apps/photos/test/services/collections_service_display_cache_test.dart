import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/collection_meta_event.dart';
import 'package:photos/events/collection_updated_event.dart';
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/services/collections_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;
  late CollectionsService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await service.disposeForTesting();
  });

  test('file updates invalidate the collection count cache', () async {
    var loadCountCalls = 0;
    service = _service(preferences, count: (_) async => ++loadCountCalls);
    final collection = _collection(1);

    expect(await service.getFileCount(collection), 1);
    expect(await service.getFileCount(collection), 1);
    expect(loadCountCalls, 1);

    Bus.instance.fire(FilesUpdatedEvent([_file(collectionID: 1)]));
    await _flushBus();

    expect(await service.getFileCount(collection), 2);
    expect(loadCountCalls, 2);
  });

  test(
    'a file update leaves unrelated collection display caches intact',
    () async {
      var loadCountCalls = 0;
      var coverCalls = 0;
      final cover = _file(collectionID: 10, uploadedID: 10);
      service = _service(
        preferences,
        count: (_) async => ++loadCountCalls,
        cover: (_, _) async {
          coverCalls++;
          return cover;
        },
      );
      final collection = _collection(10);

      expect(await service.getFileCount(collection), 1);
      expect(await service.getCover(collection), same(cover));
      Bus.instance.fire(FilesUpdatedEvent([_file(collectionID: 1)]));
      await _flushBus();

      expect(await service.getFileCount(collection), 1);
      expect(await service.getCover(collection), same(cover));
      expect(service.getCoverCache(collection), same(cover));
      expect(loadCountCalls, 1);
      expect(coverCalls, 1);
    },
  );

  test(
    'delete everywhere invalidates albums beyond the event file rows',
    () async {
      final countCalls = <int, int>{};
      final coverCalls = <int, int>{};
      service = _service(
        preferences,
        count: (id) async =>
            countCalls.update(id, (calls) => calls + 1, ifAbsent: () => 1),
        cover: (id, _) async {
          final calls = coverCalls.update(
            id,
            (calls) => calls + 1,
            ifAbsent: () => 1,
          );
          return _file(collectionID: id, uploadedID: calls);
        },
      );
      final firstCollection = _collection(1);
      final secondCollection = _collection(2);

      expect(await service.getFileCount(firstCollection), 1);
      expect(await service.getFileCount(secondCollection), 1);
      expect(await service.getCover(firstCollection), isNotNull);
      expect(await service.getCover(secondCollection), isNotNull);
      Bus.instance.fire(
        CollectionUpdatedEvent(
          1,
          [_file(collectionID: 1, uploadedID: 1)],
          'deleteFilesEverywhere',
          type: EventType.deletedFromEverywhere,
        ),
      );
      await _flushBus();

      expect(await service.getFileCount(firstCollection), 2);
      expect(await service.getFileCount(secondCollection), 2);
      expect(await service.getCover(secondCollection), isNotNull);
      expect(countCalls, {1: 2, 2: 2});
      expect(coverCalls, {1: 1, 2: 2});
    },
  );

  test('move-from remote removal remains scoped to its collection', () async {
    var countCalls = 0;
    service = _service(preferences, count: (_) async => ++countCalls);
    final collection = _collection(10);

    expect(await service.getFileCount(collection), 1);
    Bus.instance.fire(
      CollectionUpdatedEvent(
        1,
        [_file(collectionID: 2)],
        'moveFrom',
        type: EventType.deletedFromRemote,
      ),
    );
    await _flushBus();

    expect(await service.getFileCount(collection), 1);
    expect(countCalls, 1);
  });

  test('remote-only trash invalidates all albums for uploaded IDs', () async {
    final countCalls = <int, int>{};
    service = _service(
      preferences,
      count: (id) async =>
          countCalls.update(id, (calls) => calls + 1, ifAbsent: () => 1),
    );
    final firstCollection = _collection(1);
    final secondCollection = _collection(2);

    expect(await service.getFileCount(firstCollection), 1);
    expect(await service.getFileCount(secondCollection), 1);
    Bus.instance.fire(
      FilesUpdatedEvent(
        [_file(collectionID: 1)],
        type: EventType.deletedFromRemote,
        source: 'deleteFromRemoteOnly',
      ),
    );
    await _flushBus();

    expect(await service.getFileCount(secondCollection), 2);
    expect(countCalls, {1: 1, 2: 2});
  });

  test('collection ID invalidation does not match numeric prefixes', () async {
    var coverCalls = 0;
    final cover = _file(collectionID: 10, uploadedID: 10);
    service = _service(
      preferences,
      cover: (_, _) async {
        coverCalls++;
        return cover;
      },
    );
    final collection = _collection(10);

    expect(await service.getCover(collection), same(cover));
    Bus.instance.fire(CollectionUpdatedEvent(1, [], 'update_collection_1'));
    await _flushBus();

    expect(service.getCoverCache(collection), same(cover));
    expect(await service.getCover(collection), same(cover));
    expect(coverCalls, 1);
  });

  test('sort metadata invalidates only that album cover', () async {
    var coverCalls = 0;
    var countCalls = 0;
    final firstCover = _file(collectionID: 1, uploadedID: 31);
    final secondCover = _file(collectionID: 1, uploadedID: 32);
    service = _service(
      preferences,
      cover: (_, _) async => ++coverCalls == 1 ? firstCover : secondCover,
      count: (_) async => ++countCalls,
    );
    final collection = _collection(1);

    expect(await service.getCover(collection), same(firstCover));
    expect(await service.getFileCount(collection), 1);
    Bus.instance.fire(
      CollectionMetaEvent(1, CollectionMetaEventType.sortChanged),
    );
    await _flushBus();

    expect(await service.getCover(collection), same(secondCover));
    expect(await service.getFileCount(collection), 1);
    expect(coverCalls, 2);
    expect(countCalls, 1);
  });

  test('an in-flight count read retries after a collection update', () async {
    final firstRead = Completer<int>();
    var loadCountCalls = 0;
    service = _service(
      preferences,
      count: (_) {
        loadCountCalls++;
        return loadCountCalls == 1 ? firstRead.future : Future.value(7);
      },
    );
    final collection = _collection(1);

    final countFuture = service.getFileCount(collection);
    await _flushBus();
    Bus.instance.fire(
      CollectionUpdatedEvent(1, [_file(collectionID: 1)], 'move'),
    );
    await _flushBus();
    firstRead.complete(2);

    expect(await countFuture, 7);
    expect(service.getCachedFileCount(collection), 7);
    expect(loadCountCalls, 2);
  });

  test('an in-flight cover read cannot repopulate after deletion', () async {
    final oldCoverRead = Completer<EnteFile?>();
    final oldCover = _file(collectionID: 1, uploadedID: 11);
    final currentCover = _file(collectionID: 1, uploadedID: 12);
    var coverReadCalls = 0;
    service = _service(
      preferences,
      cover: (_, _) {
        coverReadCalls++;
        return coverReadCalls == 1
            ? oldCoverRead.future
            : Future.value(currentCover);
      },
    );
    final collection = _collection(1);

    final coverFuture = service.getCover(collection);
    await _flushBus();
    Bus.instance.fire(
      CollectionUpdatedEvent(1, [
        _file(collectionID: 1, uploadedID: 11),
      ], 'deleteFilesEverywhere'),
    );
    await _flushBus();
    oldCoverRead.complete(oldCover);

    expect(await coverFuture, same(currentCover));
    expect(service.getCoverCache(collection), same(currentCover));
    expect(coverReadCalls, 2);
  });

  test('an in-flight newest-file read retries after a file update', () async {
    final firstRead = Completer<Map<int, int>>();
    var loadCalls = 0;
    service = _service(
      preferences,
      newestFileTimes: () {
        loadCalls++;
        return loadCalls == 1 ? firstRead.future : Future.value({1: 200});
      },
    );

    final newestTimeFuture = service.getCollectionIDToNewestFileTime();
    await _flushBus();
    Bus.instance.fire(FilesUpdatedEvent([_file(collectionID: 1)]));
    await _flushBus();
    firstRead.complete({1: 100});

    expect(await newestTimeFuture, {1: 200});
    expect(loadCalls, 2);
  });

  test(
    'clearCache clears display caches and invalidates pending reads',
    () async {
      final firstRead = Completer<int>();
      var loadCountCalls = 0;
      var coverCalls = 0;
      var newestCalls = 0;
      final firstCover = _file(collectionID: 1, uploadedID: 21);
      final secondCover = _file(collectionID: 1, uploadedID: 22);
      service = _service(
        preferences,
        count: (_) {
          loadCountCalls++;
          return loadCountCalls == 1 ? firstRead.future : Future.value(9);
        },
        cover: (_, _) async => ++coverCalls == 1 ? firstCover : secondCover,
        newestFileTimes: () async => {1: ++newestCalls},
      );
      final collection = _collection(1);

      expect(await service.getCover(collection), same(firstCover));
      expect(await service.getCollectionIDToNewestFileTime(), {1: 1});
      final countFuture = service.getFileCount(collection);
      await _flushBus();
      service.clearCache();
      firstRead.complete(1);

      expect(await countFuture, 9);
      expect(service.getCachedFileCount(collection), 9);
      expect(loadCountCalls, 2);
      expect(await service.getCover(collection), same(secondCover));
      expect(await service.getCollectionIDToNewestFileTime(), {1: 2});
      expect(coverCalls, 2);
      expect(newestCalls, 2);
    },
  );
}

CollectionsService _service(
  SharedPreferences preferences, {
  Future<EnteFile?> Function(int collectionID, int uploadedFileID)?
  uploadedCover,
  Future<EnteFile?> Function(int collectionID, bool ascending)? cover,
  Future<int> Function(int collectionID)? count,
  Future<Map<int, int>> Function()? newestFileTimes,
}) => CollectionsService.forTesting(
  preferences: preferences,
  loadUploadedCover: uploadedCover ?? (_, _) async => null,
  loadCollectionCover: cover ?? (_, _) async => null,
  loadCollectionFileCount: count ?? (_) async => 0,
  loadNewestFileTimes: newestFileTimes ?? () async => const {},
);

Future<void> _flushBus() => Future<void>.delayed(Duration.zero);

Collection _collection(int id) => Collection(
  id,
  User(id: 1, email: 'test@example.com'),
  '',
  null,
  'Album $id',
  null,
  null,
  CollectionType.album,
  CollectionAttributes(),
  [],
  [],
  0,
);

EnteFile _file({required int collectionID, int uploadedID = 1}) => EnteFile()
  ..uploadedFileID = uploadedID
  ..collectionID = collectionID
  ..ownerID = 1
  ..fileType = FileType.image;
