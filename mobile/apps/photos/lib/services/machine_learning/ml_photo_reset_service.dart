import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/face/face.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/body_recognition_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";

class MLPhotoResetResult {
  final int resetPhotoCount;
  final List<int> failedFileIDs;

  const MLPhotoResetResult({
    required this.resetPhotoCount,
    required this.failedFileIDs,
  });
}

/// Clears saved ML data for selected owned, uploaded photos.
class MLPhotoResetService {
  MLPhotoResetService._();

  static final instance = MLPhotoResetService._();
  final _logger = Logger("MLPhotoResetService");

  Future<MLPhotoResetResult> reset(List<EnteFile> files) async {
    final byID = <int, EnteFile>{
      for (final file in files)
        if (file.isOwner && file.uploadedFileID != null)
          file.uploadedFileID!: file,
    };
    if (byID.isEmpty) {
      return const MLPhotoResetResult(resetPhotoCount: 0, failedFileIDs: []);
    }

    final db = MLDataDB.instance;
    final facesByFile = <int, List<Face>>{};
    for (final fileID in byID.keys) {
      final faces = await db.getFacesForGivenFileID(fileID) ?? <Face>[];
      facesByFile[fileID] = faces;
    }

    final successfulFileIDs = <int>{};
    final failedFileIDs = <int>[];
    final fileIDs = byID.keys.toList();
    const batchSize = 4;
    for (var start = 0; start < fileIDs.length; start += batchSize) {
      final end = start + batchSize < fileIDs.length
          ? start + batchSize
          : fileIDs.length;
      final batch = fileIDs.sublist(start, end);
      final outcomes = await Future.wait(
        batch.map((fileID) async {
          try {
            await fileDataService.updateFileDataAllowingPartialMetadata(
              byID[fileID]!,
              (latest) {
                var changed = false;
                for (final key in const ["face", "clip", "body"]) {
                  changed = latest.remoteRawData.remove(key) != null || changed;
                }
                return changed;
              },
            );
            return (fileID, true);
          } catch (e, s) {
            _logger.warning("Failed to reset ML data for file $fileID", e, s);
            return (fileID, false);
          }
        }),
      );
      for (final outcome in outcomes) {
        if (outcome.$2) {
          successfulFileIDs.add(outcome.$1);
        } else {
          failedFileIDs.add(outcome.$1);
        }
      }
    }

    if (successfulFileIDs.isNotEmpty) {
      final successfulFaces = <String>{
        for (final fileID in successfulFileIDs) ...
          (facesByFile[fileID] ?? []).map((face) => face.faceID),
      };
      await _clearFaceAssignments(db, successfulFaces, successfulFileIDs);

      final localIDs = successfulFileIDs.toList();
      const localBatchSize = 200;
      for (var start = 0; start < localIDs.length; start += localBatchSize) {
        final end = start + localBatchSize < localIDs.length
            ? start + localBatchSize
            : localIDs.length;
        final batch = localIDs.sublist(start, end);
        await db.deleteFaceIndexForFiles(batch);
        await db.deleteClipEmbeddings(batch);
        await db.deleteBodyIndexes(batch);
      }
      BodyRecognitionService.instance.invalidateCaches();
      await fileDataService.syncFDStatus();
      Bus.instance.fire(PeopleChangedEvent());
    }

    return MLPhotoResetResult(
      resetPhotoCount: successfulFileIDs.length,
      failedFileIDs: failedFileIDs,
    );
  }

  Future<void> _clearFaceAssignments(
    IMLDataDB<int> db,
    Set<String> faceIDs,
    Set<int> fileIDs,
  ) async {
    final persons = await PersonService.instance.getPersons();
    final touchedPersonIDs = <String>{};
    final emptiedClusters = <(String, String)>{};
    for (final person in persons) {
      final assigned = <ClusterInfo>[];
      var assignedChanged = false;
      for (final cluster in person.data.assigned) {
        final remaining = cluster.faces.difference(faceIDs);
        if (remaining.length != cluster.faces.length) {
          assignedChanged = true;
          touchedPersonIDs.add(person.remoteID);
          if (remaining.isEmpty) {
            emptiedClusters.add((person.remoteID, cluster.id));
          } else {
            assigned.add(ClusterInfo(id: cluster.id, faces: remaining));
          }
        } else {
          assigned.add(cluster);
        }
      }
      final rejected = person.data.rejectedFaceIDs
          .where((id) => !faceIDs.contains(id))
          .toList();
      final manual = person.data.manuallyAssigned
          .where((id) => !fileIDs.contains(id))
          .toList();
      final avatar = faceIDs.contains(person.data.avatarFaceID);
      if (assignedChanged ||
          rejected.length != person.data.rejectedFaceIDs.length ||
          manual.length != person.data.manuallyAssigned.length ||
          avatar) {
        touchedPersonIDs.add(person.remoteID);
        final data = person.data.copyWith(
          assigned: assigned,
          rejectedFaceIDs: rejected,
          manuallyAssigned: manual,
        );
        if (avatar) data.avatarFaceID = null;
        await PersonService.instance.updatePerson(person.copyWith(data: data));
      }
    }

    for (final entry in emptiedClusters) {
      await db.removeClusterToPerson(
        personID: entry.$1,
        clusterID: entry.$2,
      );
    }
    for (final personID in touchedPersonIDs) {
      await db.removeFaceIdCachedForPersonOrCluster(personID);
    }

    if (faceIDs.isEmpty) return;
    final faceToCluster = await db.getFaceIdsToClusterIds(faceIDs);
    final mappings = <String, String>{};
    final touchedClusters = <String>{};
    for (final entry in faceToCluster.entries) {
      final clusterID = entry.value;
      if (clusterID == null) continue;
      mappings[entry.key] = clusterID;
      touchedClusters.add(clusterID);
    }
    if (mappings.isNotEmpty) {
      await db.removeFaceIdToClusterId(mappings);
    }
    for (final clusterID in touchedClusters) {
      await db.deleteClusterSummary(clusterID);
      await db.removeFaceIdCachedForPersonOrCluster(clusterID);
    }
  }
}
