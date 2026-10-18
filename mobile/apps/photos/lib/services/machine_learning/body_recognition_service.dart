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
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/face_thumbnail_generator.dart";
import "package:photos/services/machine_learning/ml_model_download_service.dart";
import "package:photos/services/search_service.dart";
import "package:photos/src/rust/api/ml_indexing_api.dart" as rust;
import "package:photos/utils/ml_util.dart";

class BodyRecognitionService {
  static final instance = BodyRecognitionService._();
  BodyRecognitionService._();
  final _logger = Logger("BodyRecognitionService");
  Map<int, String> _rawIndexes = {};
  Map<int, BodyIndex> _parsedIndexes = {};
  int _indexRevision = 0;
  String? _matchKey;
  List<BodyMatch> _matches = const [];

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
    if (identical(data, _rawIndexes)) return _parsedIndexes;
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
    return result;
  }

  void invalidateCaches() {
    _rawIndexes = {};
    _parsedIndexes = {};
    _indexRevision++;
    _matchKey = null;
    _matches = const [];
  }

  Future<List<BodyMatch>> matches(List<EnteFile> files) async {
    final indices = await indexes();
    if (indices.isEmpty) return [];
    final persons = await PersonService.instance.getPersonsMap();
    final facePersons = <String, String>{};
    for (final person in persons.values) {
      for (final faceID in await MLDataDB.instance.getFaceIDsForPerson(
        person.remoteID,
      )) {
        facePersons[faceID] = person.remoteID;
      }
    }
    final clusters = await MLDataDB.instance.getAllClusterIdToFaceIDs();
    for (final cluster in clusters.entries) {
      for (final faceID in cluster.value) {
        facePersons.putIfAbsent(faceID, () => "cluster:${cluster.key}");
      }
    }
    final times = {
      for (final file in files)
        if (file.uploadedFileID != null && file.creationTime != null)
          file.uploadedFileID!: file.creationTime!,
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

  Future<List<BodyGroup>> groups(List<EnteFile> files) async =>
      groupBodyMatches(await matches(files), {
        for (final f in files)
          if (f.uploadedFileID != null && f.creationTime != null)
            f.uploadedFileID!: f.creationTime!,
      });

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

  Future<void> acceptGroup(
    PersonEntity person,
    String reference, {
    Map<int, BodyDetection>? suggestionSnapshot,
  }) async {
    final members = suggestionSnapshot != null && suggestionSnapshot.isNotEmpty
        ? [
            for (final entry in suggestionSnapshot.entries)
              (entry.key, entry.value),
          ]
        : await groupMembers(reference);
    final files = await FilesDB.instance.getFileIDToFileFromIDs(
      members.map((m) => m.$1).toList(),
    );
    // Check all current partitions before introducing any manual photo tags.
    final ids = files.keys.toList();
    final checkedMetadata = <int, FileDataEntity>{};
    for (int start = 0; start < ids.length; start += 200) {
      final end = start + 200 < ids.length ? start + 200 : ids.length;
      final batch = ids.sublist(start, end).toSet();
      final response = await fileDataService.getFilesData(batch);
      if (response.fetchErrorFileIDs.isNotEmpty) {
        throw StateError("Metadata fetch failed");
      }
      // Retain at most one batch of snapshots for reuse during the write phase.
      for (final entry in response.data.entries) {
        if (checkedMetadata.length >= 200) break;
        checkedMetadata[entry.key] = entry.value;
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
    await _updateGroup(files, members, (fileID, body) {
      body.bindReviewGroup(reference);
      final previous = body.decisions[person.remoteID];
      body.decisions[person.remoteID] = {
        "status": "accepted",
        "addedManual":
            assigned.addedFileIds.contains(fileID) ||
            (previous is Map && previous["addedManual"] == true),
      };
    }, initialMetadata: checkedMetadata);
  }

  Future<void> rejectGroup(
    String personID,
    String reference, {
    Map<int, BodyDetection>? suggestionSnapshot,
  }) async {
    final members = suggestionSnapshot != null && suggestionSnapshot.isNotEmpty
        ? [
            for (final entry in suggestionSnapshot.entries)
              (entry.key, entry.value),
          ]
        : await groupMembers(reference);
    final files = await FilesDB.instance.getFileIDToFileFromIDs(
      members.map((m) => m.$1).toList(),
    );
    await _updateGroup(files, members, (_, body) {
      body.bindReviewGroup(reference);
      body.decisions[personID] = {"status": "rejected"};
    });
  }

  Future<void> _updateGroup(
    Map<int, EnteFile> files,
    List<(int, BodyDetection)> members,
    void Function(int, BodyDetection) update, {
    Map<int, FileDataEntity>? initialMetadata,
  }) async {
    final bodiesByFile = <int, Set<String>>{};
    for (final member in members) {
      if (files.containsKey(member.$1)) {
        bodiesByFile.putIfAbsent(member.$1, () => {}).add(member.$2.bodyID);
      }
    }
    final fileIDs = bodiesByFile.keys.toList();
    // Different files are independent. Keep each file's changes in a single
    // conflict-checked update so two bodies never race over the same mldata.
    const batchSize = 4;
    for (var start = 0; start < fileIDs.length; start += batchSize) {
      final end = start + batchSize < fileIDs.length
          ? start + batchSize
          : fileIDs.length;
      final batch = fileIDs.sublist(start, end);
      final metadata = <int, FileDataEntity>{
        for (final id in batch)
          if (initialMetadata?[id] != null) id: initialMetadata![id]!,
      };
      final missing = batch.where((id) => !metadata.containsKey(id)).toSet();
      if (missing.isNotEmpty) {
        final response = await fileDataService.getFilesData(missing);
        if (response.fetchErrorFileIDs.isNotEmpty) {
          throw StateError("Metadata fetch failed");
        }
        metadata.addAll(response.data);
      }
      await Future.wait(
        batch.map((fileID) async {
          final entity = await fileDataService.updateFileData(files[fileID]!, (
            latest,
          ) {
            final index = latest.bodyIndex;
            if (index == null) throw StateError("Body index is unavailable");
            for (final bodyID in bodiesByFile[fileID]!) {
              update(
                fileID,
                index.detections.firstWhere((b) => b.bodyID == bodyID),
              );
            }
            latest.putBody(index);
            return true;
          }, initialData: metadata[fileID]);
          await store(MLDataDB.instance, fileID, entity.bodyIndex!);
        }),
      );
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

  Future<Map<int, Uint8List?>> crop(EnteFile file, String bodyID) async {
    final index = (await indexes())[file.uploadedFileID];
    if (index == null) return {};
    final members = await groupMembers(bodyID);
    final body = members.firstWhere((m) => m.$1 == file.uploadedFileID).$2;
    final crops = await FaceThumbnailGenerator.instance.generateFaceThumbnails(
      await getImagePathForML(file),
      [body.box],
    );
    return {file.uploadedFileID!: crops.first};
  }
}
