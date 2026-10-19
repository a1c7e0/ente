import "package:flutter_test/flutter_test.dart";
import "package:photos/models/ml/face/person.dart";
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

    test("excludes clusters assigned to named and hidden people", () {
      final persons = [
        PersonEntity(
          "named-person",
          PersonData(
            name: "Alex",
            assigned: [
              ClusterInfo(id: "named-cluster", faces: {"1_0"}),
            ],
          ),
        ),
        PersonEntity(
          "hidden-person",
          PersonData(
            name: "",
            isHidden: true,
            assigned: [
              ClusterInfo(id: "hidden-cluster", faces: {"2_0"}),
            ],
          ),
        ),
      ];
      final eligible = AutoUnnamedPersonService.eligibleClusters(
        threshold: 1,
        clusterToFaceIDs: {
          "named-cluster": ["1_0"],
          "hidden-cluster": ["2_0"],
          "unassigned-cluster": ["3_0"],
        },
        assignedClusterIDs: AutoUnnamedPersonService.assignedClusterIDs(
          persons,
        ),
        assignedFaceIDs: AutoUnnamedPersonService.assignedFaceIDs(persons),
        uploadedFileIDs: {1, 2, 3},
      );

      expect(eligible, ["unassigned-cluster"]);
    });

    test("an existing unnamed person prevents duplicate selection", () {
      final existingUnnamed = PersonEntity(
        "person-id",
        PersonData(
          name: "",
          isUnnamed: true,
          assigned: [
            ClusterInfo(id: "cluster", faces: {"1_0"}),
          ],
        ),
      );
      final eligible = AutoUnnamedPersonService.eligibleClusters(
        threshold: 1,
        clusterToFaceIDs: {
          "cluster": ["1_0"],
        },
        assignedClusterIDs: AutoUnnamedPersonService.assignedClusterIDs([
          existingUnnamed,
        ]),
        assignedFaceIDs: AutoUnnamedPersonService.assignedFaceIDs([
          existingUnnamed,
        ]),
        uploadedFileIDs: {1},
      );

      expect(eligible, isEmpty);
    });

    test("zero disables creation", () {
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
