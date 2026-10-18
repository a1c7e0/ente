import "dart:async";
import "dart:convert";

import "package:computer/computer.dart";
import "package:dio/dio.dart";
import "package:flutter/foundation.dart" show Uint8List;
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/files_db.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/gateways/files/file_data_gateway.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/clip.dart";
import "package:photos/models/ml/ml_versions.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/filedata/model/enc_file_data.dart";
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/services/filedata/model/response.dart";
import "package:photos/utils/file_key.dart";
import "package:photos/utils/gzip.dart";
import "package:photos/utils/ml_util.dart" show facesFromRemoteMLData;
import "package:shared_preferences/shared_preferences.dart";

const _maxMLDataBytes = 4 * 1024 * 1024;

class FileDataService {
  static final Computer _computer = Computer.shared();
  final _logger = Logger("FileDataService");
  final SharedPreferences _prefs;
  final FileDataGateway _gateway;
  late Map<int, PreviewInfo> previewIds;
  Future<void>? _syncFDStatusFuture;

  FileDataService(this._prefs, this._gateway) {
    _logger.info("FileDataService constructor called");
    previewIds = <int, PreviewInfo>{};
  }

  // Update the local preview cache without syncing after every upload.
  void appendPreview(int id, String objectId, int objectSize) {
    if (previewIds.containsKey(id)) return;
    previewIds[id] = PreviewInfo(objectId: objectId, objectSize: objectSize);
  }

  Future<void> putFileData(EnteFile file, FileDataEntity data) async {
    data.validate();
    await _putFileData(file, data);
  }

  Future<void> _putFileData(EnteFile file, FileDataEntity data) async {
    final ChaChaEncryptionResult encryptionResult = await gzipAndEncryptJson(
      data.remoteRawData,
      getFileKey(file),
    );

    try {
      await _gateway.putFileData(
        fileID: file.uploadedFileID!,
        type: data.type.toJson(),
        encryptedData: encryptionResult.encData,
        decryptionHeader: encryptionResult.header,
        lastUpdatedAt: data.updatedAt ?? 0,
      );
    } catch (e, s) {
      _logger.severe("putDerivedMetaData failed", e, s);
      rethrow;
    }
  }

  // Reapply a subtype update to the newest encrypted metadata after a conflict.
  // A false result adopts existing data without replacing it.
  Future<FileDataEntity> updateFileData(
    EnteFile file,
    FutureOr<bool> Function(FileDataEntity) update, {
    DataType type = DataType.mlData,
    FileDataEntity? initialData,
  }) => _updateFileData(file, update, type: type, initialData: initialData);

  // Reset operations may write an empty ML map. Keep normal indexing writes
  // validated while allowing resets to preserve unknown or non-ML metadata.
  Future<FileDataEntity> updateFileDataAllowingPartialMetadata(
    EnteFile file,
    FutureOr<bool> Function(FileDataEntity) update, {
    DataType type = DataType.mlData,
    FileDataEntity? initialData,
  }) => _updateFileData(
    file,
    update,
    type: type,
    allowPartialMetadata: true,
    initialData: initialData,
  );

  Future<FileDataEntity> _updateFileData(
    EnteFile file,
    FutureOr<bool> Function(FileDataEntity) update, {
    required DataType type,
    bool allowPartialMetadata = false,
    FileDataEntity? initialData,
  }) async {
    final fileID = file.uploadedFileID!;
    if (initialData != null &&
        (initialData.fileID != fileID || initialData.type != type)) {
      throw ArgumentError("Metadata snapshot does not match the file and type");
    }
    for (int attempt = 0; attempt < 3; attempt++) {
      // A caller that already batch-fetched metadata can reuse that version on
      // the first attempt. Conflicts still fetch and merge the latest object.
      FileDataEntity? entity = attempt == 0 && initialData?.updatedAt != null
          ? initialData
          : null;
      if (entity == null) {
        final response = await getFilesData({fileID}, type: type);
        if (response.fetchErrorFileIDs.contains(fileID)) {
          throw StateError("Metadata fetch failed");
        }
        entity =
            response.data[fileID] ??
            (FileDataEntity.empty(fileID, type)..updatedAt = 0);
      }
      if (!await update(entity)) return entity;
      try {
        if (allowPartialMetadata) {
          await _putFileData(file, entity);
        } else {
          await putFileData(file, entity);
        }
        return entity;
      } on DioException catch (e) {
        if (e.response?.statusCode != 409 || attempt == 2) rethrow;
      }
    }
    throw StateError("Metadata update failed");
  }

  Future<FileDataResponse> getFilesData(
    Set<int> fileIds, {
    DataType type = DataType.mlData,
  }) async {
    try {
      final res = await _gateway.fetchFileData(
        fileIDs: fileIds.toList(),
        type: type.toJson(),
      );
      final remoteEntries = res['data'] as List;
      final pendingIndexFiles = res['pendingIndexFileIDs'] as List;
      final errFileIds = res['errFileIDs'] as List;

      final List<EncryptedFileData> encFileData = <EncryptedFileData>[];
      for (var entry in remoteEntries) {
        encFileData.add(EncryptedFileData.fromMap(entry));
      }
      final fileIdToDataMap = await decryptRemoteFileData(encFileData);
      return FileDataResponse(
        fileIdToDataMap,
        fetchErrorFileIDs: Set<int>.from(errFileIds.map((x) => x as int)),
        pendingIndexFileIDs: Set<int>.from(
          pendingIndexFiles.map((x) => x as int),
        ),
      );
    } catch (e, s) {
      _logger.severe("Failed to get embeddings", e, s);
      rethrow;
    }
  }

  Future<Map<int, FileDataEntity>> decryptRemoteFileData(
    List<EncryptedFileData> remoteData,
  ) async {
    final result = <int, FileDataEntity>{};
    if (remoteData.isEmpty) {
      return result;
    }
    final inputs = <_DecoderInput>[];
    final fileMap = await FilesDB.instance.getFileIDToFileFromIDs(
      remoteData.map((e) => e.fileID).toList(),
    );
    for (final data in remoteData) {
      final file = fileMap[data.fileID];
      if (file == null) {
        continue;
      }
      final fileKey = getFileKey(file);
      final input = _DecoderInput(data, fileKey);
      inputs.add(input);
    }
    return _computer.compute<Map<String, dynamic>, Map<int, FileDataEntity>>(
      _decryptFileDataComputer,
      param: {"inputs": inputs},
    );
  }

  Future<void> syncFDStatus() {
    final existing = _syncFDStatusFuture;
    if (existing != null) {
      _logger.info("syncFDStatus already running, joining existing run");
      return existing;
    }
    final future = _syncFDStatusInternal();
    _syncFDStatusFuture = future;
    return future.whenComplete(() {
      if (identical(_syncFDStatusFuture, future)) {
        _syncFDStatusFuture = null;
      }
    });
  }

  Future<void> _syncFDStatusInternal() async {
    if (isLocalGalleryMode) {
      _logger.fine("Skipping file data sync in local gallery mode");
      return;
    }
    final previousStatusCursor = _prefs.getInt("fd.lastSyncTime") ?? 0;
    try {
      bool hasMoreData = false;
      do {
        final lastTime = _prefs.getInt("fd.lastSyncTime") ?? 0;
        final res = await _gateway.getStatusDiff(lastUpdatedAt: lastTime);
        final data = (res["diff"] ?? []) as List;
        final List<FDStatus> result = [];
        int maxUpdatedAt = lastTime;
        for (var entry in data) {
          result.add(FDStatus.fromJson(entry));
          if (entry["updatedAt"] > maxUpdatedAt) {
            maxUpdatedAt = entry["updatedAt"];
          }
        }
        await MLDataDB.instance.putFDStatus(result);
        await _prefs.setInt("fd.lastSyncTime", maxUpdatedAt);
        _logger.info('found ${result.length} fd entries');
        hasMoreData = result.isNotEmpty;
        previewIds = await MLDataDB.instance.getFileIDsVidPreview();
      } while (hasMoreData);
      try {
        if (await _syncMLData(initialCursor: previousStatusCursor)) {
          Bus.instance.fire(PeopleChangedEvent());
        }
      } catch (e, s) {
        _logger.warning(
          "ML data sync failed; retaining the original file-data sync",
          e,
          s,
        );
      }
    } catch (e) {
      if (previewIds.isEmpty) {
        previewIds = await MLDataDB.instance.getFileIDsVidPreview();
      }
      _logger.severe("Failed to syncDiff", e);
      rethrow;
    }
  }

  Future<bool> _syncMLData({required int initialCursor}) async {
    if (!hasGrantedMLConsent || !localSettings.remoteFetchEnabled) return false;
    bool changed = false;
    while (true) {
      final since = _prefs.getInt("ml.fd.lastSyncTime") ?? initialCursor;
      final response = await _gateway.getStatusDiff(lastUpdatedAt: since);
      final diff = (response["diff"] ?? []) as List;
      if (diff.isEmpty) return changed;
      final existing = await MLDataDB.instance.bodyIndexes();
      final faces = await MLDataDB.instance.faceIndexedFileIds();
      final clips = await MLDataDB.instance.clipIndexedFileWithVersion();
      final statuses = diff
          .map((d) => FDStatus.fromJson(d as Map<String, dynamic>))
          .toList();
      final ids = statuses
          .where(
            (s) =>
                s.type == DataType.mlData.value &&
                !s.isDeleted &&
                (existing.containsKey(s.fileID) ||
                    faces.containsKey(s.fileID) ||
                    clips.containsKey(s.fileID)),
          )
          .map((s) => s.fileID)
          .toList();
      for (int start = 0; start < ids.length; start += 200) {
        final end = start + 200 < ids.length ? start + 200 : ids.length;
        final fetched = await getFilesData(ids.sublist(start, end).toSet());
        if (fetched.fetchErrorFileIDs.isNotEmpty) {
          throw StateError("ML metadata fetch failed");
        }
        for (final entity in fetched.data.values) {
          final remoteFaces = facesFromRemoteMLData(entity);
          if (remoteFaces != null && faces.containsKey(entity.fileID)) {
            final local =
                await MLDataDB.instance.getFacesForGivenFileID(entity.fileID) ??
                [];
            final localJSON = local.map((f) => jsonEncode(f.toJson())).toList()
              ..sort();
            final remoteJSON =
                remoteFaces.map((f) => jsonEncode(f.toJson())).toList()..sort();
            if (jsonEncode(localJSON) != jsonEncode(remoteJSON)) {
              await MLDataDB.instance.deleteFaceIndexForFiles([entity.fileID]);
              await MLDataDB.instance.bulkInsertFaces(remoteFaces);
              changed = true;
            }
          }
          final remoteClip = entity.getClipEmbeddingIfCompatible(clipMlVersion);
          if (remoteClip != null && clips.containsKey(entity.fileID)) {
            await MLDataDB.instance.putClip([
              ClipEmbedding(
                fileID: entity.fileID,
                embedding: remoteClip.embedding,
                version: remoteClip.version,
              ),
            ]);
          }

          final raw = entity.remoteRawData["body"];
          if (raw is Map<String, dynamic> &&
              (entity.bodyIndex != null || entity.hasUnsupportedBody)) {
            final encoded = jsonEncode(entity.bodyIndex?.toJson() ?? raw);
            if (existing[entity.fileID] != encoded) {
              await MLDataDB.instance.putBodyIndex(
                entity.fileID,
                encoded,
                (raw["version"] as num).toInt(),
              );
              changed = true;
            }
          } else if (raw == null && existing.containsKey(entity.fileID)) {
            await MLDataDB.instance.deleteBodyIndexes([entity.fileID]);
            changed = true;
          }
        }
      }
      final deleted = statuses
          .where((s) => s.isDeleted && s.type == DataType.mlData.value)
          .map((s) => s.fileID)
          .toList();
      await MLDataDB.instance.deleteBodyIndexes(deleted);
      if (deleted.any(existing.containsKey)) changed = true;
      final until = statuses.fold<int>(
        since,
        (last, s) => s.updatedAt > last ? s.updatedAt : last,
      );
      await _prefs.setInt("ml.fd.lastSyncTime", until);
    }
  }
}

Future<Map<int, FileDataEntity>> _decryptFileDataComputer(
  Map<String, dynamic> args,
) async {
  final result = <int, FileDataEntity>{};
  final inputs = args["inputs"] as List<_DecoderInput>;
  final logger = Logger("FileDataService");
  for (final input in inputs) {
    try {
      final decodedJson = decryptAndUnzipJsonSync(
        input.decryptionKey,
        encryptedData: input.data.encryptedData,
        header: input.data.decryptionHeader,
        maxOutputBytes: _maxMLDataBytes,
      );
      result[input.data.fileID] = FileDataEntity.fromRemote(
        input.data.fileID,
        input.data.type,
        decodedJson,
      )..updatedAt = input.data.updatedAt;
    } on FormatException catch (e, s) {
      logger.warning(
        "Ignoring unparseable ML data for file id ${input.data.fileID}",
        e,
        s,
      );
    }
  }
  return result;
}

class _DecoderInput {
  final EncryptedFileData data;
  final Uint8List decryptionKey;

  _DecoderInput(this.data, this.decryptionKey);
}
