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
    for (final body in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: lightThemeData,
          home: Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: FileFaceWidget(
                EnteFile()..uploadedFileID = 1,
                key: ValueKey(body),
                clusterID: body ? "body:1_1" : "face-cluster",
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
