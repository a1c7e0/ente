import "package:flutter_test/flutter_test.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/services/machine_learning/face_ml/feedback/cluster_feedback.dart";
import "package:photos/ui/viewer/people/review_suggestion_changes.dart";

void main() {
  final person = PersonEntity("person", PersonData(name: "Alex"));
  ClusterSuggestion suggestion(String clusterID) =>
      ClusterSuggestion(person, clusterID, 0.1, false, [
        EnteFile()
          ..uploadedFileID = 7
          ..generatedID = 10,
      ], []);
  for (final clusterID in ["face-cluster", "body-group:example"]) {
    final candidates = [suggestion(clusterID)];
    test("$clusterID invalidates deleted photos by uploaded ID", () {
      expect(
        reviewSuggestionsAffectedBy(
          FilesUpdatedEvent([
            EnteFile()
              ..uploadedFileID = 7
              ..generatedID = 20,
          ], type: EventType.deletedFromEverywhere),
          candidates,
        ),
        isTrue,
      );
      expect(
        reviewSuggestionsAffectedBy(
          FilesUpdatedEvent([
            EnteFile()..uploadedFileID = 8,
          ], type: EventType.deletedFromEverywhere),
          candidates,
        ),
        isFalse,
      );
    });
    test("$clusterID ignores move-from and decoration-only changes", () {
      expect(
        reviewSuggestionsAffectedBy(
          FilesUpdatedEvent(
            candidates.first.filesInCluster,
            source: "moveFrom",
            type: EventType.deletedFromRemote,
          ),
          candidates,
        ),
        isFalse,
      );
      expect(
        reviewSuggestionsAffectedBy(
          FilesUpdatedEvent(
            candidates.first.filesInCluster,
            type: EventType.coverChanged,
          ),
          candidates,
        ),
        isFalse,
      );
    });
    test("$clusterID requeries membership after a mixed-grouping edit", () {
      expect(
        reviewSuggestionsAffectedBy(
          PeopleChangedEvent(
            source: clusterID,
            type: PeopleEventType.removedFaceFromCluster,
            relevantFaceIDs: ["7_face"],
          ),
          candidates,
        ),
        isTrue,
      );
      expect(
        reviewSuggestionsAffectedBy(
          PeopleChangedEvent(
            source: "other-cluster",
            type: PeopleEventType.removedFilesFromCluster,
          ),
          candidates,
        ),
        isFalse,
      );
    });
    test("$clusterID reloads after an unscoped group split in preview", () {
      expect(
        reviewSuggestionsAffectedBy(
          PeopleChangedEvent(),
          candidates,
          previewOpen: true,
        ),
        isTrue,
      );
      expect(
        reviewSuggestionsAffectedBy(PeopleChangedEvent(), candidates),
        isFalse,
      );
    });
  }
}
