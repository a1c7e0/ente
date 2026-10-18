import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/models/ml/face/box.dart";
import "package:photos/ui/settings/debug/ml_detection_preview.dart";

void main() {
  const box = MLDebugBox(
    FaceBox(x: 0.25, y: 0.1, width: 0.5, height: 0.6),
    "B1 0.95",
    Colors.orange,
  );

  test("normalized boxes use the fitted image size", () {
    expect(
      box.rectFor(const Size(200, 100)),
      const Rect.fromLTRB(50, 10, 150, 70),
    );
    const edge = MLDebugBox(
      FaceBox(x: -0.1, y: 0.8, width: 1.3, height: 0.5),
      "edge",
      Colors.green,
    );
    expect(
      edge.rectFor(const Size(200, 100)),
      const Rect.fromLTRB(0, 80, 200, 100),
    );
  });

  testWidgets("letterboxing and zoom keep the image and boxes together", (
    tester,
  ) async {
    for (final size in [const Size(300, 600), const Size(600, 300)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        const MaterialApp(
          home: MLDetectionPreview(
            image: ColoredBox(key: ValueKey("image"), color: Colors.black),
            imageSize: Size(400, 200),
            boxes: [box],
          ),
        ),
      );
      final expected = applyBoxFit(
        BoxFit.contain,
        const Size(400, 200),
        size,
      ).destination;
      expect(tester.getSize(find.byKey(const ValueKey("image"))), expected);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey("image"))),
        Offset(
          (size.width - expected.width) / 2,
          (size.height - expected.height) / 2,
        ),
      );
      final viewer = find.byType(InteractiveViewer);
      expect(
        find.descendant(of: viewer, matching: find.byType(CustomPaint)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets("edge labels do not crash in a tiny viewport", (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 4,
            height: 4,
            child: MLDetectionPreview(
              image: ColoredBox(color: Colors.black),
              imageSize: Size(400, 200),
              boxes: [box],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
