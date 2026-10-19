import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:path_provider_platform_interface/path_provider_platform_interface.dart";
import "package:photos/db/ml/dart_db.dart";

void main() {
  late Directory directory;
  late PathProviderPlatform previousPathProvider;

  setUpAll(() async {
    previousPathProvider = PathProviderPlatform.instance;
    directory = await Directory.systemTemp.createTemp("profile_review_db_");
    PathProviderPlatform.instance = _PathProvider(directory.path);
  });

  tearDownAll(() async {
    await (await DartMLDataDB.instance.asyncDB).close();
    PathProviderPlatform.instance = previousPathProvider;
    await directory.delete(recursive: true);
  });

  test(
    "only pose-only singletons can bypass the review quality exclusion",
    () async {
      final db = await DartMLDataDB.instance.asyncDB;
      final fixtures = [
        ("clear-profile", 0.9, 300.0, 1),
        ("blurred-profile", 0.9, 49.0, 1),
        ("weak-profile", 0.82, 199.0, 1),
        ("score-boundary", 0.8, 300.0, 1),
        ("clear-frontal", 0.9, 300.0, 0),
        ("blurred-frontal", 0.9, 20.0, 0),
        ("multi-profile", 0.9, 300.0, 1),
        ("multi-profile", 0.9, 300.0, 1),
      ];
      for (var i = 0; i < fixtures.length; i++) {
        final (cluster, score, blur, sideways) = fixtures[i];
        await db.execute(
          "INSERT INTO faces (file_id, face_id, detection, embedding, score, blur, is_sideways) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [i, "${i}_0", "{}", Uint8List(0), score, blur, sideways],
        );
        await db.execute(
          "INSERT INTO face_clusters (face_id, cluster_id) VALUES (?, ?)",
          ["${i}_0", cluster],
        );
      }
      final allBad = await DartMLDataDB.instance
          .getBadFaceSingletonClusterIDs();
      expect(allBad, {
        "clear-profile",
        "blurred-profile",
        "weak-profile",
        "score-boundary",
        "blurred-frontal",
      });
      final qualityBad = await DartMLDataDB.instance
          .getBadFaceSingletonClusterIDs(includeSideways: false);
      expect(qualityBad, {
        "blurred-profile",
        "weak-profile",
        "score-boundary",
        "blurred-frontal",
      });
      expect(allBad.difference(qualityBad), {"clear-profile"});
    },
  );
}

class _PathProvider extends PathProviderPlatform {
  _PathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
