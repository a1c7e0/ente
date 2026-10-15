import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/db/offline_files_db.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/face/box.dart";
import "package:photos/models/ml/face/face.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/body_recognition_service.dart";
import "package:photos/services/machine_learning/ml_model_download_service.dart";
import "package:photos/services/machine_learning/ml_process_lock.dart";
import "package:photos/services/machine_learning/webgpu_execution_policy.dart";
import "package:photos/src/rust/api/ml_indexing_api.dart" as rust;
import "package:photos/ui/settings/debug/ml_detection_preview.dart";
import "package:photos/utils/ml_util.dart";

// Opt in at build time; do not enable internal-user flags or change normal ML.
const mlDetectionDiagnosticsEnabled = bool.fromEnvironment("enteMLDiagnostics");

class MLDetectionDebugPage extends StatefulWidget {
  final EnteFile file;

  const MLDetectionDebugPage({required this.file, super.key});

  @override
  State<MLDetectionDebugPage> createState() => _MLDetectionDebugPageState();
}

class _MLDetectionDebugPageState extends State<MLDetectionDebugPage> {
  final _logger = Logger("MLDetectionDebug");
  String? _path;
  Size? _imageSize;
  int? _fileKey;
  List<Face> _faces = [];
  BodyIndex? _body;
  List<rust.RustBodyDetection>? _rawBodies;
  bool _faceIndexPresent = false;
  bool _showFaces = true;
  bool _showBodies = true;
  bool _busy = true;
  String _status = "Loading saved detections";
  String? _error;
  String _source = "Saved index";
  StreamSubscription<(String, int, int)>? _progress;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSaved());
  }

  @override
  void dispose() {
    unawaited(_progress?.cancel());
    super.dispose();
  }

  Future<void> _loadSaved() async {
    try {
      final file = widget.file;
      final db = isLocalGalleryMode
          ? MLDataDB.localGalleryInstance
          : MLDataDB.instance;
      _fileKey = isLocalGalleryMode
          ? (await OfflineFilesDB.instance.getLocalIntIdsForLocalIds([
              if (file.localID != null) file.localID!,
            ]))[file.localID]
          : file.uploadedFileID;
      if (_fileKey != null) {
        final faces = await db.getFacesForGivenFileID(_fileKey!);
        _faceIndexPresent = faces != null;
        _faces = (faces ?? <Face>[]).where((f) => f.score > 0).toList();
        final raw = (await db.bodyIndexes())[_fileKey];
        _body = raw == null ? null : BodyIndex.tryParse(jsonDecode(raw));
      }
      final path = await getImagePathForML(file);
      final codec = await ui.instantiateImageCodec(
        await File(path).readAsBytes(),
      );
      try {
        final frame = await codec.getNextFrame();
        _imageSize = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      _path = path;
    } catch (e, s) {
      _logger.warning("Could not load detection preview", e, s);
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runOnce() async {
    if (_busy ||
        _path == null ||
        !hasGrantedMLConsent ||
        !localSettings.isMLLocalIndexingEnabled) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = "Preparing models";
    });
    try {
      final attempt = await MlProcessLock.instance.tryRunExclusive(
        MlOperation.indexing,
        () async {
          if (!mounted) return;
          _progress = MLModelDownloadService.instance.progressStream.listen((
            e,
          ) {
            if (mounted) {
              setState(() {
                _status = e.$3 > 0
                    ? "${e.$1}: ${e.$2 * 100 ~/ e.$3}%"
                    : "Downloading ${e.$1}";
              });
            }
          });
          await MLModelDownloadService.instance.ensureModelsDownloaded(
            onlyIndexingModels: true,
          );
          if (!mounted) return;
          if (!hasGrantedMLConsent ||
              !localSettings.isMLLocalIndexingEnabled ||
              !MLModelDownloadService.instance.areIndexingModelsDownloaded) {
            throw StateError("ML consent or local indexing was disabled");
          }
          setState(() => _status = "Running face and body inference");
          final watch = Stopwatch()..start();
          final key = _fileKey ?? 0;
          final result = await analyzeImageRust({
            "enteFileID": key,
            "filePath": _path!,
            "runFaces": true,
            "runClip": false,
            "runPets": false,
            "enableWebGpu": await webGpuExecutionPolicy.isEligible(),
            "assetsDir": await MLModelDownloadService.instance
                .getAssetsDirectory(),
          });
          final faces = (result.faces ?? []).map((face) {
            return Face.fromFaceResult(face, key, result.decodedImageSize);
          }).toList();
          final raw = await rust.analyzeBodiesRust(
            fileId: key,
            imagePath: _path!,
            assetsDir: await MLModelDownloadService.instance
                .getAssetsDirectory(),
          );
          final body = BodyRecognitionService.fromRust(raw, faces);
          if (!mounted) return;
          setState(() {
            _faces = faces;
            _faceIndexPresent = true;
            _body = body;
            _rawBodies = raw.detections;
            _source = "Trial: ${watch.elapsedMilliseconds} ms (not saved)";
          });
        },
        background: false,
      );
      if (attempt != MlLockAttempt.ran && mounted) {
        setState(
          () => _error = "ML is busy (${attempt.name}). Try again later.",
        );
      }
    } catch (e, s) {
      _logger.warning("Detection trial failed", e, s);
      if (mounted) setState(() => _error = e.toString());
    } finally {
      await _progress?.cancel();
      _progress = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bodies = _body?.detections ?? <BodyDetection>[];
    final canRun =
        hasGrantedMLConsent &&
        localSettings.isMLLocalIndexingEnabled &&
        !_busy &&
        _path != null;
    return Scaffold(
      appBar: AppBar(title: const Text("ML detections")),
      body: Column(
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_source),
                    Text(
                      "Face: ${_faceIndexPresent ? _faces.length : "not indexed"} · "
                      "Body: ${_body == null ? "not indexed" : bodies.length}",
                    ),
                    if (_rawBodies != null)
                      Text(
                        "${_rawBodies!.length} raw body detections; "
                        "${_rawBodies!.length - bodies.length} excluded "
                        "by face association",
                      ),
                    const Text(
                      "Green: face · Orange: body · *: linked to a face",
                    ),
                    if (_rawBodies != null &&
                        _rawBodies!.length > bodies.length)
                      const Text("Red: detected, excluded from the body index"),
                    const Text("Body embedding: $bodyModel"),
                    if (_busy) ...[
                      const LinearProgressIndicator(),
                      Text(_status),
                    ],
                    if (_error != null)
                      SelectableText(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilterChip(
                          label: const Text("Faces"),
                          selected: _showFaces,
                          onSelected: (value) =>
                              setState(() => _showFaces = value),
                        ),
                        FilterChip(
                          label: const Text("Bodies"),
                          selected: _showBodies,
                          onSelected: (value) =>
                              setState(() => _showBodies = value),
                        ),
                        FilledButton(
                          onPressed: canRun ? _runOnce : null,
                          child: const Text("Run once (no save)"),
                        ),
                      ],
                    ),
                    const Text(
                      "Trial uses the current models on this photo only. "
                      "It does not save or sync detections, or rescan your library. "
                      "ML consent and local indexing must be enabled.",
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: _path == null || _imageSize == null
                ? const SizedBox.shrink()
                : MLDetectionPreview(
                    imageSize: _imageSize!,
                    image: Image.file(File(_path!), fit: BoxFit.fill),
                    boxes: [
                      if (_showBodies && _rawBodies != null)
                        for (final body in _rawBodies!)
                          if (!bodies.any((d) => d.bodyID == body.bodyId))
                            MLDebugBox(
                              FaceBox(
                                x: body.boxXyxy[0],
                                y: body.boxXyxy[1],
                                width: body.boxXyxy[2] - body.boxXyxy[0],
                                height: body.boxXyxy[3] - body.boxXyxy[1],
                              ),
                              "Excluded ${body.score.toStringAsFixed(2)}",
                              Colors.redAccent,
                            ),
                      if (_showBodies)
                        for (final (i, body) in bodies.indexed)
                          MLDebugBox(
                            body.box,
                            "B${i + 1}${body.linkedFaceID == null ? "" : "*"} "
                            "${body.score.toStringAsFixed(2)}",
                            Colors.orange,
                          ),
                      if (_showFaces)
                        for (final (i, face) in _faces.indexed)
                          MLDebugBox(
                            face.detection.box,
                            "F${i + 1} ${face.score.toStringAsFixed(2)}",
                            Colors.greenAccent,
                          ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
