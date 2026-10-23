import "dart:convert";

import "package:photos/db/files_db.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/body_feedback_service.dart";

/// Clears a person's body-review feedback while preserving generated indexes.
class BodyPersonResetService {
  BodyPersonResetService._();

  static final instance = BodyPersonResetService._();

  Future<void> clearReviewData(String personID) async {
    // Body review feedback is synchronized through encrypted remote mldata.
    if (isLocalGalleryMode) return;

    final indexes = await BodyFeedbackService.instance.overlay(
      await MLDataDB.instance.bodyIndexes(),
    );
    final fileIDs = (await BodyFeedbackService.instance.pendingFilesForPerson(
      personID,
    )).toList();
    for (final entry in indexes.entries) {
      try {
        final bodyIndex = BodyIndex.tryParse(jsonDecode(entry.value));
        if (bodyIndex != null &&
            bodyIndex.detections.any(
              (body) => body.decisions.containsKey(personID),
            )) {
          if (!fileIDs.contains(entry.key)) fileIDs.add(entry.key);
        }
      } catch (_) {
        // An invalid local index cannot contain actionable review data.
      }
    }
    if (fileIDs.isEmpty) return;

    final files = await FilesDB.instance.getFileIDToFileFromIDs(fileIDs);
    final stalePending = fileIDs
        .where((id) => !files.containsKey(id) && !indexes.containsKey(id))
        .toList();
    if (stalePending.isNotEmpty) {
      await BodyFeedbackService.instance.discardPerson(personID, stalePending);
      fileIDs.removeWhere(stalePending.contains);
    }
    final missingFileIDs = fileIDs.where((id) => !files.containsKey(id));
    if (missingFileIDs.isNotEmpty) {
      throw StateError(
        "Cannot reset body review data for unavailable photos: "
        "${missingFileIDs.length} photo(s)",
      );
    }

    // Bound metadata reads and writes so a large body index does not create an
    // unbounded request burst during a person reset.
    const metadataBatchSize = 200;
    const writeBatchSize = 4;
    for (var start = 0; start < fileIDs.length; start += metadataBatchSize) {
      final end = start + metadataBatchSize < fileIDs.length
          ? start + metadataBatchSize
          : fileIDs.length;
      final batch = fileIDs.sublist(start, end);
      final response = await fileDataService.getFilesData(batch.toSet());
      if (response.fetchErrorFileIDs.isNotEmpty) {
        throw StateError("Could not fetch body review metadata");
      }

      for (
        var writeStart = 0;
        writeStart < batch.length;
        writeStart += writeBatchSize
      ) {
        final writeEnd = writeStart + writeBatchSize < batch.length
            ? writeStart + writeBatchSize
            : batch.length;
        final writeBatch = batch.sublist(writeStart, writeEnd);
        await Future.wait(
          writeBatch.map((fileID) async {
            final file = files[fileID]!;
            var changed = false;
            final updated = await fileDataService.updateFileData(file, (
              latest,
            ) {
              final bodyIndex = latest.bodyIndex;
              if (bodyIndex == null) return false;
              for (final body in bodyIndex.detections) {
                if (body.decisions.remove(personID) == null) continue;
                changed = true;
              }
              if (changed) latest.putBody(bodyIndex);
              return changed;
            }, initialData: response.data[fileID]);
            await BodyFeedbackService.instance.discardPerson(personID, [
              fileID,
            ]);
            if (changed && updated.bodyIndex != null) {
              await MLDataDB.instance.putBodyIndex(
                fileID,
                jsonEncode(updated.bodyIndex!.toJson()),
                updated.bodyIndex!.version,
              );
            }
          }),
        );
      }
    }
  }
}
