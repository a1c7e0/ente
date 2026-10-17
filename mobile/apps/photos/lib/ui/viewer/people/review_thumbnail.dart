import "dart:async";
import "dart:math" as math;
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:photos/models/ml/face/box.dart";
import "package:photos/ui/viewer/people/face_thumbnail_squircle.dart";

/// Encoded and decoded pixels are both ready before a review becomes eligible.
class ReviewThumbnail {
  ReviewThumbnail._(this.image, this.imageSize, this.bodyBox);

  final ImageProvider image;
  final Size imageSize;
  final FaceBox? bodyBox;

  static Future<ReviewThumbnail> prepare(
    Uint8List bytes, {
    FaceBox? bodyBox,
  }) async {
    final image = MemoryImage(bytes);
    final stream = image.resolve(ImageConfiguration.empty);
    final completed = Completer<Size>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completed.isCompleted) {
          completed.complete(
            Size(info.image.width.toDouble(), info.image.height.toDouble()),
          );
        }
        info.dispose();
      },
      onError: (Object error, StackTrace? stack) {
        if (!completed.isCompleted) completed.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    try {
      final imageSize = await completed.future;
      if (bodyBox != null) {
        BodyReviewGeometry.fit(imageSize, bodyBox, const Size.square(1));
      }
      return ReviewThumbnail._(image, imageSize, bodyBox);
    } finally {
      stream.removeListener(listener);
    }
  }
}

class BodyReviewGeometry {
  const BodyReviewGeometry(this.imageRect, this.bodyRect);

  final Rect imageRect;
  final Rect bodyRect;

  factory BodyReviewGeometry.fit(Size source, FaceBox box, Size viewport) {
    final body = Rect.fromLTWH(
      box.x * source.width,
      box.y * source.height,
      box.width * source.width,
      box.height * source.height,
    ).intersect(Offset.zero & source);
    if (body.isEmpty || !body.isFinite) {
      throw ArgumentError.value(box, "box", "Body box is outside the photo");
    }
    final scale = math.min(
      viewport.width / body.width,
      viewport.height / body.height,
    );
    final origin = viewport.center(Offset.zero) - body.center * scale;
    return BodyReviewGeometry(
      origin & Size(source.width * scale, source.height * scale),
      Rect.fromLTWH(
        origin.dx + body.left * scale,
        origin.dy + body.top * scale,
        body.width * scale,
        body.height * scale,
      ),
    );
  }
}

class ReviewThumbnailWidget extends StatelessWidget {
  const ReviewThumbnailWidget(this.thumbnail, {super.key});

  final ReviewThumbnail thumbnail;

  @override
  Widget build(BuildContext context) {
    final box = thumbnail.bodyBox;
    if (box == null) {
      return SizedBox.expand(
        child: Image(image: thumbnail.image, fit: BoxFit.cover),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = BodyReviewGeometry.fit(
          thumbnail.imageSize,
          box,
          constraints.biggest,
        );
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fromRect(
                rect: geometry.imageRect,
                child: Image(image: thumbnail.image, fit: BoxFit.fill),
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: BodyReviewDimPainter(geometry.bodyRect),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class BodyReviewDimPainter extends CustomPainter {
  const BodyReviewDimPainter(this.bodyRect);

  final Rect bodyRect;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = faceThumbnailSquircleBorderRadius(bodyRect.shortestSide);
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRSuperellipse(radius.toRSuperellipse(bodyRect));
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(BodyReviewDimPainter oldDelegate) =>
      oldDelegate.bodyRect != bodyRect;
}
