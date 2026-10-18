import "package:flutter_test/flutter_test.dart";
import "package:photos/services/machine_learning/face_ml/person/auto_unnamed_person_service.dart";

void main() {
  group("AutoUnnamedPersonService", () {
    test("requires the threshold in distinct uploaded owner photos", () {
      final eligible = AutoUnnamedPersonService.eligibleClusters(
        threshold: 3,
        clusterToFaceIDs: {
          // Two face detections in file 10 count as one uploaded photo.
          "at-threshold": ["10_0", "10_1", "11_0", "12_0"],
          "below-threshold": ["20_0", "20_1", "21_0", "999_0"],
        },
        assignedClusterIDs: const {},
        assignedFaceIDs: const {},
        uploadedFileIDs: {10, 11, 12, 20, 21},
      );

      expect(eligible, ["at-threshold"]);
    });

    test("excludes locally or remotely assigned clusters and faces", () {
      final eligible = AutoUnnamedPersonService.eligibleClusters(
        threshold: 1,
        clusterToFaceIDs: {
          "assigned-cluster": ["1_0"],
          "remapped-cluster": ["2_0"],
          "unassigned-cluster": ["3_0"],
        },
        assignedClusterIDs: {"assigned-cluster"},
        assignedFaceIDs: {"2_0"},
        uploadedFileIDs: {1, 2, 3},
      );

      expect(eligible, ["unassigned-cluster"]);
    });

    test("zero disables creation and deterministic IDs are stable", () {
      expect(
        AutoUnnamedPersonService.eligibleClusters(
          threshold: 0,
          clusterToFaceIDs: {
            "cluster": ["1_0"],
          },
          assignedClusterIDs: const {},
          assignedFaceIDs: const {},
          uploadedFileIDs: {1},
        ),
        isEmpty,
      );
      expect(
        AutoUnnamedPersonService.personEntityID("cluster"),
        AutoUnnamedPersonService.personEntityID("cluster"),
      );
      expect(
        AutoUnnamedPersonService.personEntityID("cluster-a"),
        isNot(AutoUnnamedPersonService.personEntityID("cluster-b")),
      );
    });

    test("limits entity creation candidates per clustering run", () {
      final clusters = {
        for (var fileID = 1; fileID <= 12; fileID++)
          "cluster-$fileID": ["${fileID}_0"],
      };
      final eligible = AutoUnnamedPersonService.eligibleClusters(
        threshold: 1,
        clusterToFaceIDs: clusters,
        assignedClusterIDs: const {},
        assignedFaceIDs: const {},
        uploadedFileIDs: {for (var fileID = 1; fileID <= 12; fileID++) fileID},
      );

      expect(eligible, hasLength(10));
    });
  });
}
