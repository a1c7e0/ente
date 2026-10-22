import "dart:convert";

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
import "package:photos/services/filedata/filedata_service.dart";
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/services/machine_learning/body_recognition_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/ml_result.dart";

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
  MLPhotoResetService({
    IMLDataDB<int>? db,
    PersonService? persons,
    FileDataService? metadata,
    void Function()? invalidateBodyCaches,
  }) : _db = db,
       _persons = persons,
       _metadata = metadata,
       _invalidateBodyCaches =
           invalidateBodyCaches ??
           (() => BodyRecognitionService.instance.invalidateCaches());

  static final instance = MLPhotoResetService();
  final IMLDataDB<int>? _db;
  final PersonService? _persons;
  final FileDataService? _metadata;
  final void Function() _invalidateBodyCaches;
  IMLDataDB<int> get _dataDB => _db ?? MLDataDB.instance;
  PersonService get _personService => _persons ?? PersonService.instance;
  FileDataService get _fileDataService => _metadata ?? fileDataService;
  final _logger = Logger("MLPhotoResetService");

  Future<MLPhotoResetResult> reset(List<EnteFile> files) async {
    final timer = Stopwatch()..start();
    final byID = _ownedUploadedFiles(files);
    final metadata = await _resetMetadata(byID, fullReset: true);
    final result = metadata.result;
    final fileIDs = byID.keys.toSet().difference(result.failedFileIDs.toSet());
    if (fileIDs.isNotEmpty) {
      final faces = await _faceIDsForFiles(fileIDs);
      final touchedPersons = await _clearFaceAssignments(
        _dataDB,
        faces,
        fileIDs,
      );
      final ids = fileIDs.toList();
      const batchSize = 200;
      for (var start = 0; start < ids.length; start += batchSize) {
        final end = start + batchSize < ids.length
            ? start + batchSize
            : ids.length;
        final batch = ids.sublist(start, end);
        await _dataDB.deleteFaceIndexForFiles(batch);
        await _dataDB.deleteClipEmbeddings(batch);
        await _dataDB.deleteBodyIndexes(batch);
      }
      await _deleteEmptyPersons(
        touchedPersons.union(metadata.bodyPersonIDs),
        metadata.bodyIndexes,
      );
      _invalidateBodyCaches();
      Bus.instance.fire(PeopleChangedEvent());
    }
    _logger.info(
      "Full ML reset: ${result.resetPhotoCount} photos, ${result.failedFileIDs.length} failures in ${timer.elapsedMilliseconds}ms",
    );
    return result;
  }

  /// Clears person and review bindings while keeping all generated ML indexes.
  Future<MLPhotoResetResult> resetPersonBindings(List<EnteFile> files) async {
    final timer = Stopwatch()..start();
    final byID = _ownedUploadedFiles(files);
    final metadata = await _resetMetadata(byID, fullReset: false);
    final result = metadata.result;
    final fileIDs = byID.keys.toSet().difference(result.failedFileIDs.toSet());
    if (fileIDs.isNotEmpty) {
      final faces = await _faceIDsForFiles(fileIDs);
      final touchedPersons = await _clearPersonBindings(
        _dataDB,
        faces,
        fileIDs,
      );
      await _deleteEmptyPersons(
        touchedPersons.union(metadata.bodyPersonIDs),
        metadata.bodyIndexes,
      );
      _invalidateBodyCaches();
      // All selected metadata and mappings are already committed locally.
      // Normal ML sync will fetch status changes; do not block this reset on a
      // full-library metadata fetch and person reconciliation.
      Bus.instance.fire(PeopleChangedEvent());
    }
    _logger.info(
      "ML binding reset: ${result.resetPhotoCount} photos, ${result.failedFileIDs.length} failures in ${timer.elapsedMilliseconds}ms",
    );
    return result;
  }

  Map<int, EnteFile> _ownedUploadedFiles(List<EnteFile> files) => {
    for (final file in files)
      if (file.isOwner && file.uploadedFileID != null)
        file.uploadedFileID!: file,
  };

  Future<Set<String>> _faceIDsForFiles(Set<int> fileIDs) async {
    final result = <String>{};
    for (final fileID in fileIDs) {
      for (final face
          in await _dataDB.getFacesForGivenFileID(fileID) ?? <Face>[]) {
        if (face.score > 0) result.add(face.faceID);
      }
    }
    return result;
  }

  Future<
    ({
      MLPhotoResetResult result,
      Set<String> bodyPersonIDs,
      Map<int, String> bodyIndexes,
    })
  >
  _resetMetadata(Map<int, EnteFile> files, {required bool fullReset}) async {
    final ids = files.keys.toList();
    final failures = <int>[];
    final bodyPersonIDs = <String>{};
    final bodyIndexes = ids.isEmpty
        ? <int, String>{}
        : Map<int, String>.of(await _dataDB.bodyIndexes());
    const readBatchSize = 200;
    const writeBatchSize = 4;
    for (var start = 0; start < ids.length; start += readBatchSize) {
      final end = start + readBatchSize < ids.length
          ? start + readBatchSize
          : ids.length;
      final batch = ids.sublist(start, end);
      try {
        final response = await _fileDataService.getFilesData(batch.toSet());
        final readable = batch
            .where((id) => !response.fetchErrorFileIDs.contains(id))
            .toList();
        failures.addAll(batch.where(response.fetchErrorFileIDs.contains));
        for (
          var writeStart = 0;
          writeStart < readable.length;
          writeStart += writeBatchSize
        ) {
          final writeEnd = writeStart + writeBatchSize < readable.length
              ? writeStart + writeBatchSize
              : readable.length;
          await Future.wait(
            readable.sublist(writeStart, writeEnd).map((id) async {
              try {
                final affectedBodyPersons = <String>{};
                final localBody = bodyIndexes[id];
                if (localBody != null) {
                  try {
                    affectedBodyPersons.addAll(
                      _acceptedBodyPersonIDs(jsonDecode(localBody)),
                    );
                  } catch (e, s) {
                    _logger.warning(
                      "Could not read local body decisions for photo $id",
                      e,
                      s,
                    );
                  }
                }
                final updated = await _fileDataService
                    .updateFileDataAllowingPartialMetadata(
                      files[id]!,
                      (latest) {
                        affectedBodyPersons.addAll(
                          _acceptedBodyPersonIDs(latest.remoteRawData["body"]),
                        );
                        if (fullReset) {
                          var changed = false;
                          for (final key in const ["face", "clip", "body"]) {
                            changed =
                                latest.remoteRawData.remove(key) != null ||
                                changed;
                          }
                          return changed;
                        }
                        final body = latest.bodyIndex;
                        if (body == null) {
                          if (latest.remoteRawData["body"] != null) {
                            throw StateError(
                              "Cannot reset review data for an unsupported body index",
                            );
                          }
                          return false;
                        }
                        var changed = false;
                        for (final detection in body.detections) {
                          if (detection.decisions.isNotEmpty) {
                            detection.decisions.clear();
                            changed = true;
                          }
                        }
                        if (changed) latest.putBody(body);
                        return changed;
                      },
                      initialData:
                          response.data[id] ??
                          (FileDataEntity.empty(id, DataType.mlData)
                            ..updatedAt = 0),
                    );
                if (!fullReset) {
                  final body = updated.bodyIndex;
                  if (body == null) {
                    await _dataDB.deleteBodyIndexes([id]);
                    bodyIndexes.remove(id);
                  } else {
                    final encoded = jsonEncode(body.toJson());
                    await _dataDB.putBodyIndex(id, encoded, body.version);
                    bodyIndexes[id] = encoded;
                  }
                }
                if (fullReset) bodyIndexes.remove(id);
                bodyPersonIDs.addAll(affectedBodyPersons);
              } catch (e, s) {
                failures.add(id);
                _logger.warning(
                  "Could not reset ML metadata for photo $id",
                  e,
                  s,
                );
              }
            }),
          );
        }
      } catch (e, s) {
        failures.addAll(batch);
        _logger.warning("Could not fetch the selected ML metadata batch", e, s);
      }
    }
    return (
      result: MLPhotoResetResult(
        resetPhotoCount: ids.length - failures.length,
        failedFileIDs: failures,
      ),
      bodyPersonIDs: bodyPersonIDs,
      bodyIndexes: bodyIndexes,
    );
  }

  bool _isSelectedFace(String id, Set<String> faceIDs, Set<int> fileIDs) =>
      faceIDs.contains(id) || fileIDs.contains(tryGetFileIdFromFaceId(id));

  Future<void> _deleteEmptyPersons(
    Set<String> touchedPersonIDs,
    Map<int, String> bodyIndexes,
  ) async {
    if (touchedPersonIDs.isEmpty) return;
    final persons = await _personService.getPersons();
    final candidates = persons
        .where(
          (person) =>
              touchedPersonIDs.contains(person.remoteID) &&
              person.data.assigned.isEmpty &&
              person.data.manuallyAssigned.isEmpty,
        )
        .map((p) => p.remoteID)
        .toSet();
    if (candidates.isEmpty) return;
    // A body-only person must survive resetting unrelated face photos.
    for (final encoded in bodyIndexes.values) {
      try {
        final raw = jsonDecode(encoded);
        if (raw is! Map || raw["detections"] is! List) {
          throw const FormatException("Unrecognized body index");
        }
        candidates.removeAll(_acceptedBodyPersonIDs(raw));
        if (candidates.isEmpty) return;
      } catch (e, s) {
        _logger.warning(
          "Keeping empty persons because a body index could not be read",
          e,
          s,
        );
        return;
      }
    }
    for (final id in candidates) {
      await _personService.deletePerson(id);
    }
  }

  Future<Set<String>> _clearPersonBindings(
    IMLDataDB<int> db,
    Set<String> faceIDs,
    Set<int> fileIDs,
  ) async {
    final persons = await _personService.getPersons();
    final touchedPersonIDs = <String>{};
    final detachedClusters = <(String, String)>{};
    for (final person in persons) {
      final assigned = <ClusterInfo>[];
      for (final cluster in person.data.assigned) {
        if (cluster.faces.any((id) => _isSelectedFace(id, faceIDs, fileIDs))) {
          detachedClusters.add((person.remoteID, cluster.id));
          touchedPersonIDs.add(person.remoteID);
        } else {
          assigned.add(cluster);
        }
      }
      final rejected = person.data.rejectedFaceIDs
          .where((id) => !_isSelectedFace(id, faceIDs, fileIDs))
          .toList();
      final manual = person.data.manuallyAssigned
          .where((id) => !fileIDs.contains(id))
          .toList();
      final avatarID = person.data.avatarFaceID;
      final avatar =
          avatarID != null && _isSelectedFace(avatarID, faceIDs, fileIDs);
      if (assigned.length != person.data.assigned.length ||
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
        await _personService.updatePerson(person.copyWith(data: data));
      }
    }

    for (final entry in detachedClusters) {
      await db.removeClusterToPerson(personID: entry.$1, clusterID: entry.$2);
      await db.removeFaceIdCachedForPersonOrCluster(entry.$2);
    }
    for (final personID in touchedPersonIDs) {
      await db.removeFaceIdCachedForPersonOrCluster(personID);
    }
    final selectedClusters = (await db.getFaceIdsToClusterIds(
      faceIDs,
    )).values.whereType<String>().toSet();
    selectedClusters.addAll(detachedClusters.map((entry) => entry.$2));
    await _clearRejectedClusters(db, selectedClusters);
    return touchedPersonIDs;
  }

  Future<Set<String>> _clearFaceAssignments(
    IMLDataDB<int> db,
    Set<String> faceIDs,
    Set<int> fileIDs,
  ) async {
    final persons = await _personService.getPersons();
    final touchedPersonIDs = <String>{};
    final emptiedClusters = <(String, String)>{};
    for (final person in persons) {
      final assigned = <ClusterInfo>[];
      var assignedChanged = false;
      for (final cluster in person.data.assigned) {
        final remaining = cluster.faces
            .where((id) => !_isSelectedFace(id, faceIDs, fileIDs))
            .toSet();
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
          .where((id) => !_isSelectedFace(id, faceIDs, fileIDs))
          .toList();
      final manual = person.data.manuallyAssigned
          .where((id) => !fileIDs.contains(id))
          .toList();
      final avatarID = person.data.avatarFaceID;
      final avatar =
          avatarID != null && _isSelectedFace(avatarID, faceIDs, fileIDs);
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
        await _personService.updatePerson(person.copyWith(data: data));
      }
    }

    for (final entry in emptiedClusters) {
      await db.removeClusterToPerson(personID: entry.$1, clusterID: entry.$2);
    }
    for (final personID in touchedPersonIDs) {
      await db.removeFaceIdCachedForPersonOrCluster(personID);
    }

    await _clearRejectedClusters(
      db,
      emptiedClusters.map((entry) => entry.$2).toSet(),
    );
    if (faceIDs.isEmpty) return touchedPersonIDs;
    final faceToCluster = await db.getFaceIdsToClusterIds(faceIDs);
    final mappings = <String, String>{};
    final touchedClusters = <String>{};
    for (final entry in faceToCluster.entries) {
      final clusterID = entry.value;
      if (clusterID == null) continue;
      mappings[entry.key] = clusterID;
      touchedClusters.add(clusterID);
    }
    await _clearRejectedClusters(db, touchedClusters);
    if (mappings.isNotEmpty) {
      await db.removeFaceIdToClusterId(mappings);
    }
    for (final clusterID in touchedClusters) {
      await db.deleteClusterSummary(clusterID);
      await db.removeFaceIdCachedForPersonOrCluster(clusterID);
    }
    return touchedPersonIDs;
  }

  Set<String> _acceptedBodyPersonIDs(dynamic raw) {
    if (raw is! Map || raw["detections"] is! List) return {};
    final result = <String>{};
    for (final detection in raw["detections"] as List) {
      final decisions = detection is Map ? detection["decisions"] : null;
      if (decisions is! Map) continue;
      for (final entry in decisions.entries) {
        if (entry.key is String &&
            entry.value is Map &&
            entry.value["status"] == "accepted") {
          result.add(entry.key as String);
        }
      }
    }
    return result;
  }

  Future<void> _clearRejectedClusters(
    IMLDataDB<int> db,
    Set<String> clusters,
  ) async {
    if (clusters.isEmpty) return;
    final rejections = await db.getPersonToRejectedSuggestions();
    for (final entry in rejections.entries) {
      for (final clusterID in entry.value.intersection(clusters)) {
        await db.removeNotPersonFeedback(
          personID: entry.key,
          clusterID: clusterID,
        );
      }
    }
  }
}
