import "dart:io";

import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/core/configuration.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/face/box.dart";
import "package:photos/models/ml/face/face.dart";
import "package:photos/module/download/thumbnail.dart";
import "package:photos/utils/face/face_thumbnail_cache.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final file = EnteFile()..uploadedFileID = 17;
  final bytes = Uint8List.fromList([1, 2, 3, 4]);

  BodyDetection body(String id) => BodyDetection(
    bodyID: id,
    box: const FaceBox(x: 0.1, y: 0.1, width: 0.3, height: 0.7),
    score: 0.9,
    embedding: const [],
  );

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp("body-crop-cache-test");
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel("plugins.flutter.io/path_provider"),
      (_) async => directory.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel("plugins.it_nomads.com/flutter_secure_storage"),
      (_) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await Configuration.instance.init(await SharedPreferences.getInstance());
  });

  tearDownAll(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel("plugins.flutter.io/path_provider"),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel("plugins.it_nomads.com/flutter_secure_storage"),
      null,
    );
    await directory.delete(recursive: true);
  });

  test(
    "body prefetch reuses the existing temporary crop and memory cache",
    () async {
      final detection = body("body:17_cached");
      final diskCrop = cachedFaceCropPath(detection.bodyID, true);
      await diskCrop.writeAsBytes(bytes);
      final first = await getCachedBodyCrop(file, detection, useFullFile: true);
      expect(first?[detection.bodyID], bytes);

      // With no source media or disk crop, this can only succeed from memory.
      await diskCrop.delete();
      final next = await getCachedBodyCrop(file, detection, useFullFile: false);
      expect(next?[detection.bodyID], bytes);
    },
  );

  test(
    "concurrent body requests share a result without replacing face crops",
    () async {
      final detection = body("body:17_concurrent");
      await cachedFaceCropPath(detection.bodyID, true).writeAsBytes(bytes);
      final face = Face.empty(17);
      final faceBytes = Uint8List.fromList([5, 6]);
      await cachedFaceCropPath(face.faceID, true).writeAsBytes(faceBytes);

      final requests = await Future.wait([
        getCachedBodyCrop(file, detection, useFullFile: true),
        getCachedBodyCrop(file, detection, useFullFile: true),
      ]);
      expect(identical(requests[0], requests[1]), isTrue);
      expect(requests[0]?[detection.bodyID], bytes);
      final faceCrops = await getCachedFaceCrops(file, [
        face,
      ], useTempCache: true);
      expect(faceCrops?[face.faceID], faceBytes);
      expect(faceCrops?.containsKey(detection.bodyID), isFalse);
    },
  );
}
