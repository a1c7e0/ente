import "dart:convert";
import "dart:typed_data";

import "package:logging/logging.dart";
import "package:photos/db/files_db.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/models/base/id.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/face/box.dart";
import "package:photos/models/ml/face/face.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/ml_model_download_service.dart";
import "package:photos/services/search_service.dart";
import "package:photos/src/rust/api/ml_indexing_api.dart" as rust;
import "package:photos/utils/face/face_thumbnail_cache.dart";

class BodyRecognitionService {
  static final instance = BodyRecognitionService._();
  BodyRecognitionService._();
  final _logger = Logger("BodyRecognitionService");
  Map<int, String> _rawIndexes = {};
  Map<int, BodyIndex> _parsedIndexes = {};
  int _indexRevision = 0;
  String? _matchKey;
  List<BodyMatch> _matches = const [];
  String? _groupMatchKey;
  List<BodyGroup> _groups = const [];

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
    final data = await MLDataDB.instance.bodyIndexes();
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
    _groupMatchKey = null;
    return result;
  }

  Future<Map<int, EnteFile>> filesByKey(List<EnteFile> files) async => {
    for (final file in files)
      if (file.uploadedFileID != null) file.uploadedFileID!: file,
  };

  Future<List<BodyMatch>> matches(List<EnteFile> files) async {
    // Local-gallery mode keeps inference and storage, without body matching.
    if (isLocalGalleryMode) return [];
    final db = MLDataDB.instance;
    final indices = await indexes();
    if (indices.isEmpty) {
      _matchKey = null;
      _matches = const [];
      return [];
    }
    final facePersons = <String, String>{};
    final persons = await PersonService.instance.getPersonsMap();
    for (final person in persons.values) {
      for (final faceID in await db.getFaceIDsForPerson(person.remoteID)) {
        facePersons[faceID] = person.remoteID;
      }
    }
    final clusters = await db.getAllClusterIdToFaceIDs();
    for (final cluster in clusters.entries) {
      for (final faceID in cluster.value) {
        facePersons.putIfAbsent(faceID, () => "cluster:${cluster.key}");
      }
    }
    final keyedFiles = await filesByKey(files);
    final times = {
      for (final entry in keyedFiles.entries)
        if (entry.value.creationTime != null)
          entry.key: entry.value.creationTime!,
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

  Future<List<BodyGroup>> groups(List<EnteFile> files) async {
    final matchesForFiles = await matches(files);
    final matchKey = _matchKey;
    if (isLocalGalleryMode || matchKey == null) {
      _groups = const [];
      _groupMatchKey = null;
      return _groups;
    }
    if (_groupMatchKey != matchKey) {
      final keyedFiles = await filesByKey(files);
      _groups = groupBodyMatches(matchesForFiles, {
        for (final entry in keyedFiles.entries)
          if (entry.value.creationTime != null)
            entry.key: entry.value.creationTime!,
      });
      _groupMatchKey = matchKey;
    }
    return _groups;
  }

  Future<List<EnteFile>> filesForCluster(
    String clusterID,
    List<EnteFile> files,
  ) async {
    final db = MLDataDB.instance;
    final clusterFiles = await db.getFileIdToClusterIds();
    final keyedFiles = await filesByKey(files);
    final ids = {
      for (final entry in clusterFiles.entries)
        if (entry.value.contains(clusterID)) entry.key,
      for (final match in await matches(files))
        if (match.automatic && match.personID == "cluster:$clusterID")
          match.fileID,
    };
    return [
      for (final id in ids)
        if (keyedFiles.containsKey(id)) keyedFiles[id]!,
    ];
  }

  /// Keep an unnamed-cluster rejection meaningful after naming or re-clustering.
  /// Local cluster IDs are not shared identities, so metadata references faces.
  Future<bool> rejectClusterMembership(EnteFile file, String clusterID) async =>
      (await rejectClusterMemberships([file], clusterID)).isNotEmpty;

  Future<List<EnteFile>> rejectClusterMemberships(
    List<EnteFile> selectedFiles,
    String clusterID,
  ) async {
    if (isLocalGalleryMode) {
      throw StateError("Cluster editing requires an Ente account");
    }
    final selected = {
      for (final file in selectedFiles)
        if (file.uploadedFileID != null) file.uploadedFileID!: file,
    };
    if (selected.isEmpty) return [];
    final files = await SearchService.instance.getAllFilesForSearch();
    final rejectedBodies = (await matches(files))
        .where(
          (match) =>
              match.automatic &&
              selected.containsKey(match.fileID) &&
              match.personID == "cluster:$clusterID",
        )
        .toList();
    if (rejectedBodies.isEmpty) return [];
    final faces = (await MLDataDB.instance.getFaceIDsForCluster(
      clusterID,
    )).toSet();
    final anchors = {
      for (final index in (await indexes()).values)
        for (final body in index.detections)
          if (faces.contains(body.linkedFaceID)) body.linkedFaceID!,
    };
    if (anchors.isEmpty) return [];
    for (final match in rejectedBodies) {
      await _updateBody(selected[match.fileID]!, match.detection.bodyID, (
        body,
      ) {
        body.raw["rejectedAnchorFaceIDs"] = {
          ...body.rejectedAnchorFaceIDs,
          ...anchors,
        }.toList()..sort();
      });
    }
    return [
      for (final id in rejectedBodies.map((match) => match.fileID).toSet())
        selected[id]!,
    ];
  }

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
    final entity = await fileDataService.updateFileData(file, (latest) {
      final index = latest.bodyIndex;
      if (index == null) throw StateError("Body index is unavailable");
      update(index.detections.firstWhere((d) => d.bodyID == bodyID));
      latest.putBody(index);
      return true;
    });
    await store(MLDataDB.instance, file.uploadedFileID!, entity.bodyIndex!);
  }

  Future<void> acceptGroup(PersonEntity person, String reference) async {
    final members = await groupMembers(reference);
    final files = await FilesDB.instance.getFileIDToFileFromIDs(
      members.map((m) => m.$1).toList(),
    );
    // Check all current partitions before introducing any manual photo tags.
    final ids = files.keys.toList();
    for (int start = 0; start < ids.length; start += 200) {
      final end = start + 200 < ids.length ? start + 200 : ids.length;
      final batch = ids.sublist(start, end).toSet();
      final response = await fileDataService.getFilesData(batch);
      if (response.fetchErrorFileIDs.isNotEmpty) {
        throw StateError("Metadata fetch failed");
      }
      for (final member in members.where((m) => batch.contains(m.$1))) {
        final index = response.data[member.$1]?.bodyIndex;
        if (index == null) throw StateError("Body index is unavailable");
        index.detections
            .firstWhere((d) => d.bodyID == member.$2.bodyID)
            .bindReviewGroup(reference);
      }
    }
    final assigned = await PersonService.instance.addManualFileAssignments(
      personID: person.remoteID,
      fileIDs: files.keys.toSet(),
    );
    for (final member in members) {
      if (!files.containsKey(member.$1)) continue;
      await _updateBody(files[member.$1]!, member.$2.bodyID, (body) {
        body.bindReviewGroup(reference);
        final previous = body.decisions[person.remoteID];
        body.decisions[person.remoteID] = {
          "status": "accepted",
          "addedManual":
              assigned.addedFileIds.contains(member.$1) ||
              (previous is Map && previous["addedManual"] == true),
        };
      });
    }
  }

  Future<void> rejectGroup(String personID, String reference) async {
    for (final member in await groupMembers(reference)) {
      final file = await FilesDB.instance.getAnyUploadedFile(member.$1);
      if (file == null) continue;
      await _updateBody(file, member.$2.bodyID, (body) {
        body.bindReviewGroup(reference);
        body.decisions[personID] = {"status": "rejected"};
      });
    }
  }

  Future<void> undoGroup(PersonEntity person, String reference) async {
    final members = await groupMembers(reference);
    final introduced = <int>{};
    for (final member in members) {
      final decision = member.$2.decisions[person.remoteID];
      if (decision is Map && decision["addedManual"] == true) {
        introduced.add(member.$1);
      }
    }
    final current = await PersonService.instance.getPerson(person.remoteID);
    if (current != null && introduced.isNotEmpty) {
      await PersonService.instance.updatePerson(
        current.copyWith(
          data: current.data.copyWith(
            manuallyAssigned: current.data.manuallyAssigned
                .where((id) => !introduced.contains(id))
                .toList(),
          ),
        ),
      );
    }
    for (final member in members) {
      final file = await FilesDB.instance.getAnyUploadedFile(member.$1);
      if (file != null) {
        await _updateBody(
          file,
          member.$2.bodyID,
          (body) => body.decisions.remove(person.remoteID),
        );
      }
    }
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
    final introduced = <String, Set<int>>{};
    for (final member in members.where((m) => selected.contains(m.$1))) {
      for (final decision in member.$2.decisions.entries) {
        if (decision.value is Map &&
            decision.value["status"] == "accepted" &&
            decision.value["addedManual"] == true) {
          introduced.putIfAbsent(decision.key, () => {}).add(member.$1);
        }
      }
    }
    for (final entry in introduced.entries) {
      final person = await PersonService.instance.getPerson(entry.key);
      if (person != null) {
        await PersonService.instance.updatePerson(
          person.copyWith(
            data: person.data.copyWith(
              manuallyAssigned: person.data.manuallyAssigned
                  .where((id) => !entry.value.contains(id))
                  .toList(),
            ),
          ),
        );
      }
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
    final entity = await fileDataService.updateFileData(file, (latest) {
      final index = latest.bodyIndex;
      if (index == null) throw StateError("Body index is unavailable");
      final body = index.detections.firstWhere((d) => d.bodyID == bodyID);
      if (decision == null) {
        body.decisions.remove(personID);
      } else {
        body.decisions[personID] = decision;
      }
      latest.putBody(index);
      return true;
    });
    await store(MLDataDB.instance, file.uploadedFileID!, entity.bodyIndex!);
  }

  Future<void> accept(PersonEntity person, EnteFile file, String bodyID) async {
    final result = await PersonService.instance.addManualFileAssignments(
      personID: person.remoteID,
      fileIDs: {file.uploadedFileID!},
    );
    await updateDecision(file, bodyID, person.remoteID, {
      "status": "accepted",
      "addedManual": result.addedFileIds.isNotEmpty,
    });
  }

  Future<void> reject(String personID, EnteFile file, String bodyID) =>
      updateDecision(file, bodyID, personID, {"status": "rejected"});

  Future<void> undo(PersonEntity person, EnteFile file, String bodyID) async {
    final index = (await indexes())[file.uploadedFileID];
    final decision = index?.detections
        .firstWhere((d) => d.bodyID == bodyID)
        .decisions[person.remoteID];
    if (decision is Map && decision["addedManual"] == true) {
      final current = await PersonService.instance.getPerson(person.remoteID);
      if (current != null) {
        await PersonService.instance.updatePerson(
          current.copyWith(
            data: current.data.copyWith(
              manuallyAssigned: current.data.manuallyAssigned
                  .where((id) => id != file.uploadedFileID)
                  .toList(),
            ),
          ),
        );
      }
    }
    await updateDecision(file, bodyID, person.remoteID, null);
  }

  Future<Map<int, Uint8List?>> crop(
    EnteFile file,
    String reference, {
    bool useFullFile = true,
  }) async {
    final fileID = file.uploadedFileID;
    if (fileID == null) return {};
    final index = (await indexes())[fileID];
    if (index == null) return {};
    BodyDetection? body;
    for (final detection in index.detections) {
      if (detection.bodyID == reference || detection.groupID == reference) {
        body = detection;
        break;
      }
    }
    if (body == null) {
      // Reuse suggestion membership for rendering. Feedback still resolves and
      // validates the current group before changing any assignments.
      if (_groupMatchKey == _matchKey && _matchKey != null) {
        for (final group in _groups) {
          if (group.id != reference) continue;
          for (final match in group.matches) {
            if (match.fileID == fileID) body = match.detection;
          }
        }
      }
      body ??= (await groupMembers(
        reference,
      )).firstWhere((member) => member.$1 == fileID).$2;
    }
    final crops = await getCachedBodyCrop(file, body, useFullFile: useFullFile);
    return {fileID: crops?[body.bodyID]};
  }
}
