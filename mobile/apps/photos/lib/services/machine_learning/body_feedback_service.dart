import "dart:async";
import "dart:convert";

import "package:logging/logging.dart";
import "package:photos/core/configuration.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/files_db.dart";
import "package:photos/db/ml/body_feedback_db.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/main.dart" show isProcessBg;
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/body_feedback.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/ml_process_lock.dart";
import "package:synchronized/synchronized.dart";

class BodyFeedbackService {
  BodyFeedbackService({
    BodyFeedbackDB? db,
    int? Function()? ownerID,
    String? Function()? token,
    Future<Map<int, EnteFile>> Function(List<int>)? files,
    Future<FileDataEntity> Function(EnteFile, bool Function(FileDataEntity))?
    updateMetadata,
    Future<void> Function(String personID, int fileID, bool assigned)?
    setManualAssignment,
    Future<void> Function(int, BodyIndex)? storeIndex,
  }) : _db = db ?? BodyFeedbackDB.instance,
       _ownerID = ownerID ?? Configuration.instance.getUserID,
       _token = token ?? Configuration.instance.getToken,
       _files = files ?? FilesDB.instance.getFileIDToFileFromIDs,
       _updateMetadata = updateMetadata ?? _updateForCurrentSession,
       _setManualAssignment =
           setManualAssignment ?? _setManualForCurrentSession,
       _storeIndex =
           storeIndex ??
           ((id, index) => MLDataDB.instance.putBodyIndex(
             id,
             jsonEncode(index.toJson()),
             index.version,
           ));

  static Future<FileDataEntity> _updateForCurrentSession(
    EnteFile file,
    bool Function(FileDataEntity) update,
  ) {
    final owner = Configuration.instance.getUserID();
    final token = Configuration.instance.getToken();
    return fileDataService.updateFileDataForSession(
      file,
      update,
      isCurrentSession: () =>
          Configuration.instance.getUserID() == owner &&
          Configuration.instance.getToken() == token,
    );
  }

  static Future<void> _setManualForCurrentSession(
    String personID,
    int fileID,
    bool assigned,
  ) {
    final owner = Configuration.instance.getUserID();
    final token = Configuration.instance.getToken();
    return PersonService.instance.setManualFileAssignmentForSession(
      personID,
      fileID,
      assigned,
      () =>
          Configuration.instance.getUserID() == owner &&
          Configuration.instance.getToken() == token,
    );
  }

  static final instance = BodyFeedbackService();
  final BodyFeedbackDB _db;
  final int? Function() _ownerID;
  final String? Function() _token;
  final Future<Map<int, EnteFile>> Function(List<int>) _files;
  final Future<FileDataEntity> Function(EnteFile, bool Function(FileDataEntity))
  _updateMetadata;
  final Future<void> Function(String, int, bool) _setManualAssignment;
  final Future<void> Function(int, BodyIndex) _storeIndex;
  final _personWrites = Lock();
  final _logger = Logger("BodyFeedbackService");
  Future<void>? _syncFuture;
  bool _syncRequested = false;

  Future<void> enqueue(Map<int, BodyFeedbackPatch> patches) async {
    final owner = _ownerID();
    final token = _token();
    if (owner == null || token == null || isLocalGalleryMode) {
      throw StateError("Body feedback requires an authenticated account");
    }
    final files = await _files(patches.keys.toList());
    if (patches.keys.any((id) => files[id]?.ownerID != owner)) {
      throw StateError("Body feedback requires owned, uploaded photos");
    }
    _ensureSession(owner, token);
    await _db.enqueue(owner, {
      for (final entry in patches.entries)
        if (entry.value.bodies.isNotEmpty) entry.key: entry.value,
    }, isCurrentSession: () => _ownerID() == owner && _token() == token);
    _ensureSession(owner, token);
  }

  /// Pending patches are always applied after remote hydration. No downloaded
  /// embedding or unrelated field is replaced by an old local metadata snapshot.
  Future<Map<int, String>> overlay(Map<int, String> raw) async {
    final owner = _ownerID();
    if (owner == null || isLocalGalleryMode) return raw;
    final pending = await _db.pending(owner);
    if (pending.isEmpty) return raw;
    final result = Map<int, String>.of(raw);
    for (final item in pending) {
      final data = raw[item.fileID];
      if (data == null) continue;
      final index = BodyIndex.tryParse(jsonDecode(data));
      if (index == null) continue;
      // A fresh reindex may no longer contain an old detection. Leave the
      // intent pending rather than inventing a body or discarding its feedback.
      final ids = index.detections.map((body) => body.bodyID).toSet();
      final visible = BodyFeedbackPatch({
        for (final entry in item.patch.bodies.entries)
          if (ids.contains(entry.key)) entry.key: entry.value,
      }, item.patch.manual);
      visible.apply(index);
      result[item.fileID] = jsonEncode(index.toJson());
    }
    return result;
  }

  Future<Set<int>> pendingFilesForPerson(String personID) async {
    final owner = _ownerID();
    if (owner == null || isLocalGalleryMode) return {};
    return {
      for (final item in await _db.pending(owner))
        if (item.patch.manual.containsKey(personID) ||
            item.patch.bodies.values.any(
              (body) => (body["decisions"] as Map).containsKey(personID),
            ))
          item.fileID,
    };
  }

  Future<Map<String, Map<int, bool>>> manualChanges() async {
    final owner = _ownerID();
    if (owner == null || isLocalGalleryMode) return {};
    final result = <String, Map<int, bool>>{};
    for (final item in await _db.pending(owner)) {
      for (final entry in item.patch.manual.entries) {
        result.putIfAbsent(entry.key, () => {})[item.fileID] =
            entry.value == true;
      }
    }
    return result;
  }

  static Set<int> applyManualChanges(
    Iterable<int> current,
    Map<int, bool>? changes,
  ) {
    final result = current.toSet();
    for (final entry in (changes ?? <int, bool>{}).entries) {
      if (entry.value) {
        result.add(entry.key);
      } else {
        result.remove(entry.key);
      }
    }
    return result;
  }

  void scheduleSync() {
    _syncRequested = true;
    if (_syncFuture != null || isLocalGalleryMode) return;
    _syncFuture = _runScheduled().whenComplete(() => _syncFuture = null);
  }

  Future<void> _runScheduled() async {
    try {
      do {
        _syncRequested = false;
        await MlProcessLock.instance.tryRunExclusive(
          MlOperation.metadataSync,
          flushWhileLocked,
          background: isProcessBg,
        );
      } while (_syncRequested);
    } catch (error, stack) {
      _logger.warning(
        "Body feedback remains pending for the next sync",
        error,
        stack,
      );
    }
  }

  /// Called inside the existing cross-engine ML lock, including normal file-data
  /// sync. Each failed photo remains durable; other photos can still progress.
  Future<void> flushWhileLocked({bool Function()? shouldStop}) async {
    final owner = _ownerID();
    final token = _token();
    if (owner == null || token == null || isLocalGalleryMode) return;
    final failed = <int>{};
    while (true) {
      if (shouldStop?.call() ?? false) return;
      _ensureSession(owner, token);
      final pending = (await _db.pending(
        owner,
      )).where((item) => !failed.contains(item.fileID)).take(200).toList();
      if (pending.isEmpty) return;
      final files = await _files(pending.map((item) => item.fileID).toList());
      for (var start = 0; start < pending.length; start += 4) {
        if (shouldStop?.call() ?? false) return;
        final batch = pending.skip(start).take(4);
        await Future.wait(
          batch.map((item) async {
            try {
              _ensureSession(owner, token);
              final file = files[item.fileID];
              if (file == null || file.ownerID != owner) {
                // A trashed/inaccessible photo must not keep retrying forever.
                await _db.acknowledge(item);
                return;
              }
              final updated = await _updateMetadata(file, (latest) {
                _ensureSession(owner, token);
                final index = latest.bodyIndex;
                if (index == null) {
                  throw StateError("Body metadata is unavailable");
                }
                item.patch.apply(index, checkGroup: true);
                latest.putBody(index);
                return true;
              });
              _ensureSession(owner, token);
              await _personWrites.synchronized(() async {
                for (final entry in item.patch.manual.entries) {
                  _ensureSession(owner, token);
                  await _setManualAssignment(
                    entry.key,
                    item.fileID,
                    entry.value == true,
                  );
                  _ensureSession(owner, token);
                }
              });
              _ensureSession(owner, token);
              await _storeIndex(item.fileID, updated.bodyIndex!);
              _ensureSession(owner, token);
              // A newer local edit (including undo) gets a new revision and must
              // survive completion of this older request.
              await _db.acknowledge(item);
            } catch (error, stack) {
              failed.add(item.fileID);
              _logger.warning(
                "Body feedback for ${item.fileID} remains pending",
                error,
                stack,
              );
            }
          }),
        );
      }
      if (owner == _ownerID() && token == _token()) {
        Bus.instance.fire(PeopleChangedEvent());
      }
    }
  }

  Future<void> discardFiles(Iterable<int> ids) async {
    final owner = _ownerID();
    if (owner != null) await _db.discardFiles(owner, ids);
  }

  Future<void> discardPerson(String personID, Iterable<int> ids) async {
    final owner = _ownerID();
    if (owner != null) await _db.discardPerson(owner, personID, ids);
  }

  void _ensureSession(int owner, String token) {
    if (_ownerID() != owner || _token() != token) {
      throw StateError("Body feedback account session changed");
    }
  }
}
