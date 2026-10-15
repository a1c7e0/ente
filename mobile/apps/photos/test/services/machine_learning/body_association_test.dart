import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:photos/models/ml/face/box.dart";
import "package:photos/models/ml/face/detection.dart";
import "package:photos/models/ml/face/face.dart";
import "package:photos/services/machine_learning/body_recognition_service.dart";
import "package:photos/src/rust/api/ml_indexing_api.dart" as rust;

void main() {
  test("diagnostics and normal indexing share face association filtering", () {
    final faces = [
      for (final (id, x) in [("face1", 0.2), ("face2", 0.6)])
        Face(
          id,
          1,
          const [],
          0.95,
          Detection(
            box: FaceBox(x: x, y: 0.1, width: 0.05, height: 0.05),
            landmarks: const [],
          ),
          100,
        ),
      Face.empty(1),
    ];
    final raw = rust.RustBodyIndex(
      width: 1000,
      height: 800,
      detections: [
        for (final (id, box) in [
          ("body:1", [0.1, 0.05, 0.4, 0.9]),
          ("body:2", [0.1, 0.05, 0.45, 0.95]),
          ("body:3", [0.1, 0.05, 0.8, 0.9]),
          ("body:4", [0.8, 0.1, 1.0, 0.9]),
        ])
          rust.RustBodyDetection(
            bodyId: id,
            boxXyxy: Float64List.fromList(box),
            score: 0.95,
            embedding: Float64List.fromList(List.filled(512, 0.1)),
          ),
      ],
    );
    final index = BodyRecognitionService.fromRust(raw, faces);
    expect((index.width, index.height), (1000, 800));
    expect(index.detections.map((d) => d.bodyID), [
      "body:1",
      "body:2",
      "body:4",
    ]);
    expect(index.detections.first.linkedFaceID, "face1");
    expect(index.detections[1].linkedFaceID, isNull);
    expect(index.detections[2].linkedFaceID, isNull);
    expect(index.detections.first.box.height, closeTo(0.85, 1e-9));
    expect(raw.detections.length, 4);
  });
}
