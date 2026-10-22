import 'package:flutter_test/flutter_test.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/collection_updated_event.dart';
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/services/search_service.dart';

void main() {
  late SearchService searchService;
  late int databaseReads;
  late List<EnteFile> databaseFiles;

  EnteFile file(int uploadedFileID) => EnteFile()
    ..uploadedFileID = uploadedFileID
    ..collectionID = 1
    ..localID = 'local-$uploadedFileID'
    ..fileType = FileType.image;

  setUp(() {
    databaseReads = 0;
    databaseFiles = [file(1)];
    searchService = SearchService.forTesting(
      loadFiles: () async {
        databaseReads++;
        return databaseFiles;
      },
    )..init();
  });

  tearDown(() async {
    await searchService.disposeForTesting();
  });

  Future<void> waitForEventDelivery() => Future<void>.delayed(Duration.zero);

  test('file caches refresh for membership and visibility updates', () async {
    Future<void> expectAllCachedFileListsToContain(int uploadedFileID) async {
      expect(
        (await searchService.getAllFilesForSearch()).map(
          (file) => file.uploadedFileID,
        ),
        [uploadedFileID],
      );
      expect(
        (await searchService.getAllFilesForHierarchicalSearch()).map(
          (file) => file.uploadedFileID,
        ),
        [uploadedFileID],
      );
      expect(
        (await searchService.getAllFilesForGenericGallery()).map(
          (file) => file.uploadedFileID,
        ),
        [uploadedFileID],
      );
    }

    Future<void> updateFilesAndExpectRefresh(
      List<FilesUpdatedEvent> events,
      int uploadedFileID,
    ) async {
      databaseFiles = [file(uploadedFileID)];
      for (final event in events) {
        Bus.instance.fire(event);
      }
      await waitForEventDelivery();
      await expectAllCachedFileListsToContain(uploadedFileID);
      expect(databaseReads, greaterThan(1));
    }

    await expectAllCachedFileListsToContain(1);
    expect(databaseReads, 1);

    // Metadata-only updates do not affect the cached file membership.
    Bus.instance.fire(
      CollectionUpdatedEvent(
        1,
        const [],
        'cover',
        type: EventType.coverChanged,
      ),
    );
    Bus.instance.fire(
      FilesUpdatedEvent(
        const [],
        source: 'people',
        type: EventType.peopleChanged,
      ),
    );
    Bus.instance.fire(
      FilesUpdatedEvent(
        const [],
        source: 'people-cluster',
        type: EventType.peopleClusterChanged,
      ),
    );
    await waitForEventDelivery();
    await expectAllCachedFileListsToContain(1);
    expect(databaseReads, 1);

    // A normal collection update covers move operations.
    await updateFilesAndExpectRefresh([
      CollectionUpdatedEvent(2, const [], 'moveTo'),
    ], 2);
    expect(databaseReads, 2);

    await updateFilesAndExpectRefresh([
      CollectionUpdatedEvent(1, const [], 'hide', type: EventType.hide),
    ], 3);
    expect(databaseReads, 3);

    await updateFilesAndExpectRefresh([
      CollectionUpdatedEvent(1, const [], 'unhide', type: EventType.unhide),
    ], 4);
    expect(databaseReads, 4);

    // Restore currently emits both events; both are delivered before the next
    // read and still cause only one lazy reload.
    await updateFilesAndExpectRefresh([
      CollectionUpdatedEvent(2, const [], 'restore'),
      FilesUpdatedEvent(const [], source: 'restore'),
    ], 5);
    expect(databaseReads, 5);
  });
}
