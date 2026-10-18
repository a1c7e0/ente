import "package:flutter_test/flutter_test.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/services/machine_learning/face_ml/person/auto_unnamed_deduplication.dart";

void main() {
  group("AutoUnnamedDeduplication", () {
    test("chooses canonical IDs and returns deterministic order", () {
      final persons = [
        _candidate("z-duplicate", ["face-3", "face-1"], "cluster-z"),
        _candidate("b-duplicate", ["face-2"], "cluster-b"),
        _candidate("a-canonical", ["face-1", "face-3"], "cluster-a"),
        _candidate("a-duplicate", ["face-2"], "cluster-a2"),
      ];

      final result = AutoUnnamedDeduplication.duplicateToCanonical(persons);

      expect(
        result,
        AutoUnnamedDeduplication.duplicateToCanonical(
          persons.reversed.toList(),
        ),
      );
      expect(result.keys.toList(), ["b-duplicate", "z-duplicate"]);
      expect(result, {
        "b-duplicate": "a-duplicate",
        "z-duplicate": "a-canonical",
      });
    });

    test("uses source face IDs even when assigned cluster IDs differ", () {
      final result = AutoUnnamedDeduplication.duplicateToCanonical([
        _candidate("second", ["face-1", "face-2"], "cluster-second"),
        _candidate("first", ["face-2", "face-1"], "cluster-first"),
      ]);

      expect(result, {"second": "first"});
    });

    test("keeps partially overlapping source groups separate", () {
      final result = AutoUnnamedDeduplication.duplicateToCanonical([
        _candidate("a1", ["face-1", "face-2"], "a1-cluster"),
        _candidate("a2", ["face-1", "face-2"], "a2-cluster"),
        _candidate("b1", ["face-2", "face-3"], "b1-cluster"),
        _candidate("b2", ["face-2", "face-3"], "b2-cluster"),
      ]);

      // Different provenance lists are never merged. Their shared assigned
      // face also protects each group from being collapsed.
      expect(result, isEmpty);
    });

    test("protects a group when a same-source member was renamed", () {
      final result = AutoUnnamedDeduplication.duplicateToCanonical([
        _candidate("candidate-a", ["face-1"], "candidate-cluster-a"),
        _candidate("candidate-b", ["face-1"], "candidate-cluster-b"),
        PersonEntity(
          "renamed-member",
          PersonData(
            name: "Sam",
            assigned: [
              ClusterInfo(id: "renamed-cluster", faces: {"face-1"}),
            ],
          ),
        ),
      ]);

      expect(result, isEmpty);
    });

    test("protects source faces assigned to another person", () {
      final result = AutoUnnamedDeduplication.duplicateToCanonical([
        _candidate("candidate-a", ["face-1"], "candidate-cluster-a"),
        _candidate("candidate-b", ["face-1"], "candidate-cluster-b"),
        PersonEntity(
          "named-person",
          PersonData(
            name: "Sam",
            assigned: [
              ClusterInfo(id: "named-cluster", faces: {"face-1"}),
            ],
          ),
        ),
      ]);

      expect(result, isEmpty);
    });

    test("protects source faces rejected by another person", () {
      final result = AutoUnnamedDeduplication.duplicateToCanonical([
        _candidate("candidate-a", ["face-1"], "candidate-cluster-a"),
        _candidate("candidate-b", ["face-1"], "candidate-cluster-b"),
        PersonEntity(
          "rejecting-person",
          PersonData(name: "", rejectedFaceIDs: ["face-1"]),
        ),
      ]);

      expect(result, isEmpty);
    });

    test("legacy unnamed people without provenance are not candidates", () {
      final result = AutoUnnamedDeduplication.duplicateToCanonical([
        _candidate("candidate-a", ["face-1"], "candidate-cluster-a"),
        _candidate("candidate-b", ["face-1"], "candidate-cluster-b"),
        PersonEntity(
          "legacy-person",
          PersonData(
            name: "",
            isUnnamed: true,
            assigned: [
              ClusterInfo(id: "legacy-cluster", faces: {"unrelated-face"}),
            ],
          ),
        ),
      ]);

      expect(result, {"candidate-b": "candidate-a"});
    });

    test("a legacy person protects overlapping source faces", () {
      final result = AutoUnnamedDeduplication.duplicateToCanonical([
        _candidate("candidate-a", ["face-1"], "candidate-cluster-a"),
        _candidate("candidate-b", ["face-1"], "candidate-cluster-b"),
        PersonEntity(
          "legacy-person",
          PersonData(
            name: "",
            isUnnamed: true,
            assigned: [
              ClusterInfo(id: "legacy-cluster", faces: {"face-1"}),
            ],
          ),
        ),
      ]);

      expect(result, isEmpty);
    });

    test("rejects empty or duplicate source provenance", () {
      final result = AutoUnnamedDeduplication.duplicateToCanonical([
        _candidate("empty-a", [], "empty-a-cluster"),
        _candidate("empty-b", [], "empty-b-cluster"),
        _candidate("duplicate-a", ["face-2", "face-2"], "dup-a-cluster"),
        _candidate("duplicate-b", ["face-2", "face-2"], "dup-b-cluster"),
      ]);

      expect(result, isEmpty);
    });

    test(
      "every kind of user feedback protects the entire exact-source group",
      () {
        final original = _candidate("modified", ["face-1"], "modified-cluster");
        final changes = [
          original.data.copyWith(name: "Alex"),
          original.data.copyWith(isHidden: true),
          original.data.copyWith(isPinned: true),
          original.data.copyWith(hideFromMemories: true),
          original.data.copyWith(avatarFaceId: "face-1"),
          original.data.copyWith(birthDate: "2000-01-01"),
          original.data.copyWith(email: "a@example.com"),
          original.data.copyWith(userID: 7),
          original.data.copyWith(rejectedFaceIDs: ["face-1"]),
          original.data.copyWith(manuallyAssigned: [42]),
          original.data.copyWith(autoCreationFaceIDs: null),
          original.data.copyWith(autoDuplicateOf: "other"),
        ];
        for (final changed in changes) {
          expect(
            AutoUnnamedDeduplication.duplicateToCanonical([
              _candidate("a", ["face-1"], "cluster-a"),
              _candidate("b", ["face-1"], "cluster-b"),
              original.copyWith(data: changed),
            ]),
            isEmpty,
            reason: changed.toJson().toString(),
          );
        }
      },
    );

    test("rejects modified candidates", () {
      final modified = <PersonEntity>[
        _candidate("avatar", ["face-1"], "avatar-cluster").copyWith(
          data: _candidate("avatar", [
            "face-1",
          ], "avatar-cluster").data.copyWith(avatarFaceId: "face-1"),
        ),
        _candidate("pinned", ["face-2"], "pinned-cluster").copyWith(
          data: _candidate("pinned", [
            "face-2",
          ], "pinned-cluster").data.copyWith(isPinned: true),
        ),
      ];
      final result = AutoUnnamedDeduplication.duplicateToCanonical([
        ...modified,
        _candidate("avatar-copy", ["face-1"], "avatar-copy-cluster"),
        _candidate("pinned-copy", ["face-2"], "pinned-copy-cluster"),
      ]);

      expect(result, isEmpty);
    });
  });
}

PersonEntity _candidate(
  String remoteID,
  List<String> sourceFaces,
  String clusterID,
) => PersonEntity(
  remoteID,
  PersonData(
    name: "",
    isUnnamed: true,
    autoCreationFaceIDs: sourceFaces,
    assigned: [ClusterInfo(id: clusterID, faces: sourceFaces.toSet())],
  ),
);
