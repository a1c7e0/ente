import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/models/ml/face/box.dart";
import "package:photos/ui/viewer/people/face_thumbnail_squircle.dart";
import "package:photos/ui/viewer/people/review_thumbnail.dart";

void main() {
  test(
    "portrait body height fills the tile using physical image dimensions",
    () {
      final geometry = BodyReviewGeometry.fit(
        const Size(1000, 500),
        const FaceBox(x: 0.4, y: 0.1, width: 0.1, height: 0.8),
        const Size.square(100),
      );
      expect(geometry.bodyRect, const Rect.fromLTWH(37.5, 0, 25, 100));
      expect(geometry.imageRect, const Rect.fromLTWH(-62.5, -12.5, 250, 125));
    },
  );

  test("wide body width fills the tile without stretching", () {
    final geometry = BodyReviewGeometry.fit(
      const Size(1000, 500),
      const FaceBox(x: 0.1, y: 0.3, width: 0.8, height: 0.4),
      const Size.square(100),
    );
    expect(geometry.bodyRect, const Rect.fromLTWH(0, 37.5, 100, 25));
    expect(
      geometry.imageRect.width / geometry.imageRect.height,
      closeTo(2, 1e-10),
    );
  });

  test("edge boxes preserve body framing instead of stretching the photo", () {
    final geometry = BodyReviewGeometry.fit(
      const Size(1000, 500),
      const FaceBox(x: 0.95, y: 0.2, width: 0.1, height: 0.6),
      const Size.square(100),
    );
    expect(geometry.bodyRect.height, 100);
    expect(geometry.bodyRect.center.dx, closeTo(50, 1e-10));
    expect(geometry.bodyRect.center.dy, closeTo(50, 1e-10));
    expect(
      geometry.imageRect.width / geometry.imageRect.height,
      closeTo(2, 1e-10),
    );
  });

  testWidgets(
    "body preview keeps aligned photo context and dims only outside its rounded box",
    (tester) async {
      late final ReviewThumbnail thumbnail;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(Colors.green, BlendMode.src);
        canvas.drawRect(
          const Rect.fromLTWH(80, 10, 20, 80),
          Paint()..color = Colors.red,
        );
        final picture = recorder.endRecording();
        final source = await picture.toImage(200, 100);
        picture.dispose();
        final encoded = await source.toByteData(format: ui.ImageByteFormat.png);
        source.dispose();
        thumbnail = await ReviewThumbnail.prepare(
          encoded!.buffer.asUint8List(),
          bodyBox: const FaceBox(x: 0.4, y: 0.1, width: 0.1, height: 0.8),
        );
      });
      const boundaryKey = ValueKey("preview");
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox.square(
                dimension: 100,
                child: FaceThumbnailSquircleClip(
                  child: ReviewThumbnailWidget(thumbnail),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      late final ByteData? data;
      await tester.runAsync(() async {
        final pixels = await boundary.toImage(pixelRatio: 1);
        data = await pixels.toByteData();
        pixels.dispose();
      });
      int channel(int x, int y, int channel) =>
          data!.getUint8((y * 100 + x) * 4 + channel);
      // Body center stays bright red, context stays green but becomes darker.
      expect(channel(50, 50, 0), 244);
      expect(channel(15, 50, 1), lessThan(100));
      expect(channel(15, 50, 1), greaterThan(40));
      // The top corner of the body window is dimmed, not left as a sharp rectangle.
      expect(channel(38, 1, 0), lessThan(160));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets("undecodable bytes cannot enter the ready queue", (tester) async {
    await tester.runAsync(() async {
      await expectLater(
        ReviewThumbnail.prepare(Uint8List.fromList([1, 2, 3])),
        throwsException,
      );
    });
  });
  test(
    "a body entirely outside the photo cannot produce infinite layout dimensions",
    () {
      expect(
        () => BodyReviewGeometry.fit(
          const Size(1000, 500),
          const FaceBox(x: 1, y: 0, width: 0.1, height: 0.5),
          const Size.square(100),
        ),
        throwsArgumentError,
      );
    },
  );

  testWidgets("face review preserves cover fit across the entire square tile", (
    tester,
  ) async {
    late final ReviewThumbnail thumbnail;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.red, BlendMode.src);
      final picture = recorder.endRecording();
      final source = await picture.toImage(20, 100);
      picture.dispose();
      final bytes = await source.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();
      thumbnail = await ReviewThumbnail.prepare(bytes!.buffer.asUint8List());
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 100,
            child: FaceThumbnailSquircleClip(
              child: ReviewThumbnailWidget(thumbnail),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final image = find.byType(Image);
    expect(tester.getSize(image), const Size.square(100));
    expect(tester.widget<Image>(image).fit, BoxFit.cover);
    expect(tester.takeException(), isNull);
  });
}
