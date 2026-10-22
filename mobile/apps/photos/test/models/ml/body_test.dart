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
    "body embedding persistence keeps a compact compatible number array",
    () {
      final index = BodyIndex(1000, 1000, [
        BodyDetection(
          bodyID: "body:1_1",
          box: const FaceBox(x: 0.1, y: 0.1, width: 0.3, height: 0.7),
          score: 0.9,
          embedding: [0.12345678, -0.00789123, ...List<double>.filled(510, 0)],
        ),
      ]);
      final raw = index.toJson();
      final detection = (raw["detections"] as List).single as Map;

      expect(raw["embeddingPrecision"], bodyEmbeddingPrecision);
      expect(detection["embedding"], isA<List<num>>());
      expect((detection["embedding"] as List).first, 0.1235);
      expect((detection["embedding"] as List)[1], -0.007891);
      expect(BodyIndex.tryParse(raw), isNotNull);
    },
  );

  test(
    "unnamed-cluster body rejections survive naming without claiming a stranger",
    () {
      final rejected = BodyDetection.fromJson({
        ...body("body:3_1").toJson(),
        "rejectedAnchorFaceIDs": ["1_face"],
      });
      final indices = {
        1: BodyIndex(1000, 1000, [body("body:1_1", face: "1_face")]),
        2: BodyIndex(1000, 1000, [
          body("body:2_1", face: "2_face", cosine: 0.9),
        ]),
        3: BodyIndex(1000, 1000, [rejected]),
      };
      for (final identity in ["cluster:unnamed", "named-person"]) {
        expect(
          matchBodyDetections(
            indices,
            {1: time, 2: time, 3: time},
            {"1_face": identity, "2_face": "another-person"},
          ),
          isEmpty,
        );
      }
      expect(rejected.toJson()["rejectedAnchorFaceIDs"], ["1_face"]);
    },
  );

  test("malformed stable anchor rejections do not enter the body index", () {
    expect(
      () => BodyDetection.fromJson({
        ...body("body:3_1").toJson(),
        "rejectedAnchorFaceIDs": [42],
      }),
      throwsFormatException,
    );
  });

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
    final raw = BodyIndex(1000, 1000, []).toJson()
      ..["extension"] = true
      ..["client"] = "desktop";
    expect(BodyIndex.tryParse(raw)?.toJson()["extension"], isTrue);
    expect(BodyIndex.tryParse(raw)?.toJson()["client"], "desktop");
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

  test("body review reset keeps detection data and extension fields", () {
    final bodyIndex = BodyIndex(1000, 1000, [body("body:1_1")]).toJson()
      ..["extension"] = "preserved";
    final detection = bodyIndex["detections"] as List;
    detection[0] = {
      ...(detection[0] as Map<String, dynamic>),
      "groupID": "body-group:1_1",
      "rejectedAnchorFaceIDs": ["1_face"],
      "decisions": {
        "person-a": {"status": "accepted"},
      },
      "futureField": 12,
    };

    final reset = clearBodyReviewData(bodyIndex);
    final resetDetection = (reset["detections"] as List).single;
    expect(reset["extension"], "preserved");
    expect(resetDetection["decisions"], isEmpty);
    expect(resetDetection.containsKey("groupID"), isFalse);
    expect(resetDetection.containsKey("rejectedAnchorFaceIDs"), isFalse);
    expect(resetDetection["futureField"], 12);
    expect(BodyIndex.tryParse(reset)?.detections.single.embedding, vector());
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
  test("similar bodies group without joining a chain or human partitions", () {
    BodyMatch item(int id, double cosine, {String? group}) => BodyMatch(
      id,
      BodyDetection.fromJson({
        ...body("body:${id}_1", cosine: cosine).toJson(),
        if (group != null) "groupID": group,
      }),
      "person-a",
      0.8,
      0.1,
    );
    final times = {1: time, 2: time, 3: time};
    expect(
      groupBodyMatches([
        item(3, 1),
        item(1, 1),
        item(2, 1),
      ], times).single.matches.length,
      3,
    );
    expect(
      groupBodyMatches([
        item(1, 1),
        item(2, 0.85),
        item(3, 0.55),
      ], times).map((g) => g.matches.length),
      [2, 1],
    );
    expect(
      groupBodyMatches([
        item(1, 1, group: "body-group:a"),
        item(2, 1, group: "body-group:b"),
      ], times).length,
      2,
    );
  });

  test(
    "a stale review cannot bind an already split body back to the old group",
    () {
      final detection = BodyDetection.fromJson({
        ...body("body:1_1").toJson(),
        "groupID": "body-group:isolated",
      });
      expect(
        () => detection.bindReviewGroup("body-group:original"),
        throwsStateError,
      );
      expect(detection.groupID, "body-group:isolated");
    },
  );
}
