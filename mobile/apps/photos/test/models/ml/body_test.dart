import "dart:math" as math;

import "package:flutter_test/flutter_test.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/face/box.dart";

List<double> vector([double cosine = 1]) => [
  cosine,
  math.sqrt(1 - cosine * cosine),
  ...List<double>.filled(510, 0),
];
BodyDetection body(String id, {String? face, double cosine = 1}) =>
    BodyDetection(
      bodyID: id,
      box: const FaceBox(x: 0.1, y: 0.1, width: 0.3, height: 0.7),
      score: 0.9,
      embedding: vector(cosine),
      linkedFaceID: face,
      decisions: {},
    );

void main() {
  const time = 1700000000000000;
  test(
    "body matching uses face anchors and a three-hour microsecond window",
    () {
      final indices = {
        1: BodyIndex(1000, 1000, [body("body:1_1", face: "1_face")]),
        2: BodyIndex(1000, 1000, [body("body:2_1")]),
      };
      final persons = {"1_face": "person-a"};
      final matches = matchBodyDetections(indices, {
        1: time,
        2: time + 1000000,
      }, persons);
      expect(matches.single.personID, "person-a");
      expect(matches.single.automatic, isTrue);
      expect(
        matchBodyDetections(indices, {
          1: time,
          2: time + const Duration(hours: 3).inMicroseconds + 1,
        }, persons),
        isEmpty,
      );
      expect(matchBodyDetections(indices, {1: time, 2: 0}, persons), isEmpty);
    },
  );

  test(
    "co-occurrence and rejected candidates cannot create an automatic stranger claim",
    () {
      final candidate = body("body:3_1");
      final indices = {
        1: BodyIndex(1000, 1000, [body("body:1_1", face: "1_face")]),
        2: BodyIndex(1000, 1000, [
          body("body:2_1", face: "2_face", cosine: 0.98),
        ]),
        3: BodyIndex(1000, 1000, [candidate]),
      };
      final persons = {"1_face": "person-a", "2_face": "person-b"};
      final times = {1: time, 2: time, 3: time};
      candidate.decisions["person-b"] = {"status": "rejected"};
      expect(
        matchBodyDetections(indices, times, persons).single.automatic,
        isFalse,
      );
      candidate.decisions["person-a"] = {"status": "rejected"};
      expect(matchBodyDetections(indices, times, persons), isEmpty);
      candidate.decisions.clear();
      expect(
        matchBodyDetections(indices, times, {
          ...persons,
          "3_face": "person-a",
          "3_other": "person-b",
        }),
        isEmpty,
      );
    },
  );

  test("invalid body data is isolated and empty results are valid", () {
    final raw = BodyIndex(1000, 1000, []).toJson()..["extension"] = true;
    expect(BodyIndex.tryParse(raw)?.toJson()["extension"], isTrue);
    expect(
      BodyIndex.tryParse({...raw, "model": "another-vector-space"}),
      isNull,
    );
    final bad = {
      ...raw,
      "detections": [
        {
          ...body("body:1_1").toJson(),
          "embedding": [1],
        },
      ],
    };
    expect(BodyIndex.tryParse(bad), isNull);
  });

  test("a prior confirmation prevents automatic reassignment", () {
    final candidate = body("body:2_1");
    candidate.decisions["removed-person"] = {"status": "accepted"};
    expect(
      matchBodyDetections(
        {
          1: BodyIndex(1000, 1000, [body("body:1_1", face: "1_face")]),
          2: BodyIndex(1000, 1000, [candidate]),
        },
        {1: time, 2: time},
        {"1_face": "person-a"},
      ),
      isEmpty,
    );
  });
}
