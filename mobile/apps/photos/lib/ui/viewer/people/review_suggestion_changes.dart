import "package:photos/events/event.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/services/machine_learning/face_ml/feedback/cluster_feedback.dart";

/// Requery membership rather than editing a suggestion's files in place. Its
/// detection snapshot and prepared thumbnails must describe the same members.
bool reviewSuggestionsAffectedBy(
  Event event,
  Iterable<ClusterSuggestion> suggestions, {
  bool previewOpen = false,
}) {
  // Splitting a group can emit an unscoped people change. Defer a fresh query
  // until returning from the preview instead of retaining its old group ID.
  if (previewOpen && event is PeopleChangedEvent) return true;
  if (event is FilesUpdatedEvent) {
    if (event.source == "moveFrom" ||
        (event.type != EventType.deletedFromEverywhere &&
            event.type != EventType.deletedFromRemote &&
            event.type != EventType.hide)) {
      return false;
    }
    final ids = event.updatedFiles
        .map((file) => file.uploadedFileID)
        .nonNulls
        .toSet();
    return suggestions.any(
      (suggestion) => suggestion.filesInCluster.any(
        (file) => ids.contains(file.uploadedFileID),
      ),
    );
  }
  if (event is PeopleChangedEvent &&
      (event.type == PeopleEventType.removedFilesFromCluster ||
          event.type == PeopleEventType.removedFaceFromCluster)) {
    return suggestions.any(
      (suggestion) => suggestion.clusterIDToMerge == event.source,
    );
  }
  return false;
}
