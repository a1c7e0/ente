import "dart:math";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:photos/generated/protos/ente/common/vector.pb.dart";
import "package:photos/services/machine_learning/face_ml/feedback/profile_review.dart";

void main() {
  late Map<String, dynamic> args;
  late Map<String, (Uint8List, int)> summaries;
  late Map<String, int> counts;
  late Map<String, Set<String>> people;

  setUp(() {
    summaries = {
      "profile": (_centroid(1), 1),
      "alice-front": (_centroid(0.8), 8),
      "bob-front": (_centroid(0.6), 5),
    };
    counts = {"profile": 1, "alice-front": 8, "bob-front": 5};
    people = {
      "alice": {"alice-front"},
      "bob": {"bob-front"},
    };
    args = {
      "profileClusterIDs": {"profile"},
      "targetPersonIDs": {"alice"},
      "personToClusterIDs": people,
      "clusterCounts": counts,
      "summaries": summaries,
    };
  });

  test("admits a clear singleton for its nearest person", () {
    expect(profileReviewMatches(args), {"profile": "alice"});
  });

  test(
    "rejects an ambiguous match instead of picking the requested person",
    () {
      summaries["bob-front"] = (_centroid(0.75), 5);
      expect(profileReviewMatches(args), isEmpty);
    },
  );

  test("compares against people outside the current review sample", () {
    summaries["bob-front"] = (_centroid(0.9), 5);
    expect(profileReviewMatches(args), isEmpty);
  });

  test("different clusters of the same person do not compete", () {
    summaries["alice-profile"] = (_centroid(0.79), 2);
    counts["alice-profile"] = 2;
    people["alice"]!.add("alice-profile");
    expect(profileReviewMatches(args), {"profile": "alice"});
  });

  test("uses every reference cluster for competing people", () {
    summaries["bob-profile"] = (_centroid(0.78), 2);
    counts["bob-profile"] = 2;
    people["bob"]!.add("bob-profile");
    expect(profileReviewMatches(args), isEmpty);
  });

  test("fails closed when a competitor centroid is missing or stale", () {
    summaries.remove("bob-front");
    expect(profileReviewMatches(args), isEmpty);
    summaries["bob-front"] = (_centroid(0.6), 4);
    expect(profileReviewMatches(args), isEmpty);
  });

  test("does not admit stale candidates, larger groups or assigned faces", () {
    summaries["profile"] = (_centroid(1), 2);
    expect(profileReviewMatches(args), isEmpty);
    counts["profile"] = 2;
    expect(profileReviewMatches(args), isEmpty);
    counts["profile"] = 1;
    summaries["profile"] = (_centroid(1), 1);
    people["alice"]!.add("profile");
    expect(profileReviewMatches(args), isEmpty);
  });

  test("retains the existing loose mean distance limit", () {
    summaries["alice-front"] = (_centroid(0.3), 8);
    summaries["bob-front"] = (_centroid(0), 5);
    expect(profileReviewMatches(args), isEmpty);
  });

  test("supports a single known person without inventing a second match", () {
    people.remove("bob");
    expect(profileReviewMatches(args), {"profile": "alice"});
  });

  test("rejects invalid reference dimensions, norms and nonfinite values", () {
    for (final values in [
      [1.0, 0.0],
      List<double>.filled(192, 0),
      [double.nan, ...List<double>.filled(191, 0)],
    ]) {
      summaries["bob-front"] = (EVector(values: values).writeToBuffer(), 5);
      expect(profileReviewMatches(args), isEmpty);
    }
  });

  test("ties between people do not become review candidates", () {
    summaries["bob-front"] = (_centroid(0.8), 5);
    args["targetPersonIDs"] = {"alice", "bob"};
    expect(profileReviewMatches(args), isEmpty);
  });

  test(
    "does not offer a profile to another person or to a co-occurring face",
    () {
      expect(
        profileReviewExclusions(
          personID: "alice",
          matches: {
            "clear": "alice",
            "same-photo": "alice",
            "other-person": "bob",
            "missing-photo": "alice",
          },
          profileFileIDs: {
            "clear": [1],
            "same-photo": [2],
            "other-person": [3],
          },
          personFileIDs: {2},
        ),
        {"same-photo", "other-person", "missing-photo"},
      );
    },
  );
}

Uint8List _centroid(double cosine) => EVector(
  values: [cosine, sqrt(1 - cosine * cosine), ...List<double>.filled(190, 0)],
).writeToBuffer();
