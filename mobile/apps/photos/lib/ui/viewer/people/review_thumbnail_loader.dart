import "package:photos/models/ml/body.dart";
import "package:photos/module/download/thumbnail.dart";
import "package:photos/services/machine_learning/face_ml/feedback/cluster_feedback.dart";
import "package:photos/ui/viewer/people/review_thumbnail.dart";
import "package:photos/ui/viewer/people/review_thumbnail_queue.dart";
import "package:photos/utils/face/face_thumbnail_cache.dart";

typedef ReviewSuggestionKey = (String, String, String);
typedef ReviewThumbnails = Map<int, ReviewThumbnail>;

/// Include representative file IDs so mixed-grouping edits cannot reuse the
/// previous selection's thumbnails. Person ID distinguishes competing matches.
ReviewSuggestionKey reviewSuggestionKey(
  ClusterSuggestion suggestion,
  int count,
) => (
  suggestion.person.remoteID,
  suggestion.clusterIDToMerge,
  suggestion.filesInCluster.take(count).map((f) => f.uploadedFileID).join(","),
);

class ReviewThumbnailLoader {
  ReviewThumbnailLoader(
    this.count, {
    this.prefetchGroups = 2,
    int? prefetchImageBudget,
  }) {
    _queue = ReviewThumbnailQueue(
      _load,
      capacity: prefetchGroups,
      maxWeight: prefetchImageBudget,
      weight: (key) => _suggestions[key]!.filesInCluster.take(count).length,
    );
  }

  final int count;
  final int prefetchGroups;
  final Map<ReviewSuggestionKey, ClusterSuggestion> _suggestions = {};
  late final ReviewThumbnailQueue<ReviewSuggestionKey, ReviewThumbnails> _queue;

  Future<({ClusterSuggestion suggestion, ReviewThumbnails thumbnails})?> next(
    Iterable<ClusterSuggestion> candidates,
  ) async {
    final list = candidates.take(prefetchGroups).toList();
    _remember(list);
    final result = await _queue.next(
      list.map((s) => reviewSuggestionKey(s, count)),
    );
    if (result == null) return null;
    return (
      suggestion: list.firstWhere(
        (s) => reviewSuggestionKey(s, count) == result.key,
      ),
      thumbnails: result.value,
    );
  }

  void prefetch(Iterable<ClusterSuggestion> candidates) {
    final list = candidates.take(prefetchGroups).toList();
    _remember(list);
    _queue.prefetch(list.map((s) => reviewSuggestionKey(s, count)));
  }

  void _remember(List<ClusterSuggestion> candidates) {
    _suggestions.clear();
    for (final suggestion in candidates) {
      _suggestions[reviewSuggestionKey(suggestion, count)] = suggestion;
    }
  }

  Future<ReviewThumbnails> _load(ReviewSuggestionKey key) async {
    final suggestion = _suggestions[key]!;
    final bodyReference = isBodyReference(suggestion.clusterIDToMerge);
    final files = suggestion.filesInCluster.take(count).toList();
    if (files.isEmpty) throw StateError("Review candidate has no photos");
    final thumbnails = await Future.wait(
      files.map((file) async {
        if (bodyReference) {
          final body = suggestion.bodyDetectionsByFile[file.uploadedFileID];
          if (body == null) throw StateError("Body detection is unavailable");
          // Reuse the gallery thumbnail download, decryption and disk cache. A
          // small review tile should not require downloading the original photo.
          final bytes = await getThumbnailFromServer(file);
          if (bytes.isEmpty) {
            throw StateError("Body review thumbnail is unavailable");
          }
          return ReviewThumbnail.prepare(bytes, bodyBox: body.box);
        }
        final bytes = await precomputeClusterFaceCrop(
          file,
          suggestion.clusterIDToMerge,
          useFullFile: true,
        );
        if (bytes == null || bytes.isEmpty) {
          throw StateError("Face review thumbnail is unavailable");
        }
        return ReviewThumbnail.prepare(bytes);
      }),
    );
    return {
      for (var i = 0; i < files.length; i++)
        files[i].uploadedFileID!: thumbnails[i],
    };
  }

  void retryFailures() => _queue.retryFailures();

  void dispose() {
    _queue.dispose();
    _suggestions.clear();
  }
}
