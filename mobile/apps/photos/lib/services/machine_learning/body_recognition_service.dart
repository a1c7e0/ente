import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:logging/logging.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/db/ml/db.dart";
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
    for (int attempt = 0; attempt < 3; attempt++) {
      final response = await fileDataService.getFilesData({fileID});
      if (response.fetchErrorFileIDs.contains(fileID)) {
        throw StateError("Body metadata fetch failed");
      }
      final entity =
          response.data[fileID] ??
          (FileDataEntity.empty(fileID, DataType.mlData)..updatedAt = 0);
      final existing = entity.bodyIndex;
      if (existing != null) {
        // Another device may have indexed or reviewed this photo meanwhile.
        await store(db, fileID, existing);
        return;
      }
      if (entity.hasUnsupportedBody) {
        final raw = entity.remoteRawData["body"] as Map<String, dynamic>;
        await db.putBodyIndex(
          fileID,
          jsonEncode(raw),
          (raw["version"] as num).toInt(),
        );
        return;
      }
      entity.putBody(generated);
      try {
        await fileDataService.putFileData(file, entity);
        await store(db, fileID, generated);
        return;
      } on DioException catch (e) {
        if (e.response?.statusCode != 409 || attempt == 2) rethrow;
      }
    }
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
    return result;
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

  Future<void> updateDecision(
    EnteFile file,
    String bodyID,
    String personID,
    Map<String, dynamic>? decision,
  ) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      final response = await fileDataService.getFilesData({
        file.uploadedFileID!,
      });
      final entity = response.data[file.uploadedFileID!];
      final index = entity?.bodyIndex;
      if (entity == null || index == null) {
        throw StateError("Body index is unavailable");
      }
      final body = index.detections.firstWhere((d) => d.bodyID == bodyID);
      if (decision == null) {
        body.decisions.remove(personID);
      } else {
        body.decisions[personID] = decision;
      }
      entity.putBody(index);
      try {
        await fileDataService.putFileData(file, entity);
        await store(MLDataDB.instance, file.uploadedFileID!, index);
        return;
      } on DioException catch (e) {
        if (e.response?.statusCode != 409 || attempt == 2) rethrow;
      }
    }
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
    final body = index.detections.firstWhere((d) => d.bodyID == bodyID);
    final crops = await FaceThumbnailGenerator.instance.generateFaceThumbnails(
      await getImagePathForML(file),
      [body.box],
    );
    return {file.uploadedFileID!: crops.first};
  }
}
