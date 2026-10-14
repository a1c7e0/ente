import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/models/file/file.dart";
import "package:photos/ui/viewer/people/file_face_widget.dart";

void main() {
  testWidgets("review preserves the body crop and existing face crop fit", (
    tester,
  ) async {
    final crop = base64Decode(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==",
    );
    for (final reference in ["body:1_1", "body-group:1_1", "face-cluster"]) {
      final body =
          reference.startsWith("body:") || reference.startsWith("body-group:");
      await tester.pumpWidget(
        MaterialApp(
          theme: lightThemeData,
          home: Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: FileFaceWidget(
                EnteFile()..uploadedFileID = 1,
                key: ValueKey(reference),
                clusterID: reference,
                faceCrop: crop,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Image>(find.byType(Image)).fit,
        body ? BoxFit.contain : BoxFit.cover,
      );
    }
  });
}
