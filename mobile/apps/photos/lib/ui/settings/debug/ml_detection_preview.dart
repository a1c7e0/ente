import "dart:math" as math;

import "package:flutter/material.dart";
import "package:photos/models/ml/face/box.dart";

class MLDebugBox {
  final FaceBox box;
  final String label;
  final Color color;

  const MLDebugBox(this.box, this.label, this.color);

  Rect rectFor(Size size) => Rect.fromLTRB(
    box.x.clamp(0.0, 1.0) * size.width,
    box.y.clamp(0.0, 1.0) * size.height,
    (box.x + box.width).clamp(0.0, 1.0) * size.width,
    (box.y + box.height).clamp(0.0, 1.0) * size.height,
  );
}

// Put the image and boxes in the same fitted, zoomable coordinate space.
class MLDetectionPreview extends StatelessWidget {
  final Widget image;
  final Size imageSize;
  final List<MLDebugBox> boxes;

  const MLDetectionPreview({
    required this.image,
    required this.imageSize,
    required this.boxes,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = applyBoxFit(
          BoxFit.contain,
          imageSize,
          constraints.biggest,
        ).destination;
        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: SizedBox.fromSize(
              size: fitted,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  image,
                  IgnorePointer(
                    child: CustomPaint(painter: _DetectionPainter(boxes)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DetectionPainter extends CustomPainter {
  final List<MLDebugBox> boxes;

  const _DetectionPainter(this.boxes);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final box in boxes) {
      final rect = box.rectFor(size);
      if (rect.isEmpty) continue;
      canvas.drawRect(
        rect,
        Paint()
          ..color = box.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      final text = TextPainter(
        text: TextSpan(
          text: box.label,
          style: TextStyle(
            color: box.color,
            backgroundColor: Colors.black87,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      text.paint(
        canvas,
        Offset(
          rect.left.clamp(0.0, math.max(0.0, size.width - text.width)),
          (rect.top - text.height).clamp(
            0.0,
            math.max(0.0, size.height - text.height),
          ),
        ),
      );
      text.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DetectionPainter oldDelegate) =>
      oldDelegate.boxes != boxes;
}
