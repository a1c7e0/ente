import "dart:typed_data";

import "package:ml_linalg/linalg.dart";
import "package:photos/generated/protos/ente/common/vector.pb.dart";

/// Finds the person for pose-only singletons without changing clustering or
/// the existing review distance thresholds. Runs in the suggestion isolate.
Map<String, String> profileReviewMatches(Map<String, dynamic> args) {
  final profileClusterIDs = args["profileClusterIDs"] as Set<String>;
  final targetPersonIDs = args["targetPersonIDs"] as Set<String>;
  final personToClusterIDs =
      args["personToClusterIDs"] as Map<String, Set<String>>;
  final clusterCounts = args["clusterCounts"] as Map<String, int>;
  final summaries = args["summaries"] as Map<String, (Uint8List, int)>;
  const maxMeanDistance = 0.65;
  const personDistanceMargin = 0.10;

  Vector? readCentroid(String clusterID) {
    final summary = summaries[clusterID];
    if (summary == null || summary.$2 != clusterCounts[clusterID]) return null;
    final values = EVector.fromBuffer(summary.$1).values;
    if (values.length != 192 || values.any((v) => !v.isFinite)) return null;
    final vector = Vector.fromList(values, dtype: DType.float32);
    if ((vector.norm() - 1).abs() > 1e-3) return null;
    return vector;
  }

  final references = <String, List<Vector>>{};
  final assignedClusterIDs = <String>{};
  for (final entry in personToClusterIDs.entries) {
    final vectors = <Vector>[];
    for (final clusterID in entry.value) {
      final vector = readCentroid(clusterID);
      // Missing competitors cannot be interpreted as evidence of a large gap.
      if (vector == null) return {};
      vectors.add(vector);
      assignedClusterIDs.add(clusterID);
    }
    if (vectors.isNotEmpty) references[entry.key] = vectors;
  }

  final matches = <String, String>{};
  for (final clusterID in profileClusterIDs) {
    if (clusterCounts[clusterID] != 1 ||
        assignedClusterIDs.contains(clusterID)) {
      continue;
    }
    final candidate = readCentroid(clusterID);
    if (candidate == null) continue;

    String? nearestPerson;
    var nearestDistance = maxMeanDistance;
    for (final personID in targetPersonIDs) {
      for (final reference in references[personID] ?? const <Vector>[]) {
        final distance = 1 - candidate.dot(reference);
        if (distance < nearestDistance) {
          nearestPerson = personID;
          nearestDistance = distance;
        }
      }
    }
    if (nearestPerson == null) continue;

    var ambiguous = false;
    for (final entry in references.entries) {
      if (entry.key == nearestPerson) continue;
      for (final reference in entry.value) {
        if (1 - candidate.dot(reference) - nearestDistance <
            personDistanceMargin) {
          ambiguous = true;
          break;
        }
      }
      if (ambiguous) break;
    }
    if (!ambiguous) matches[clusterID] = nearestPerson;
  }
  return matches;
}

/// Extra exclusions apply only to the newly admitted profile candidates.
Set<String> profileReviewExclusions({
  required String personID,
  required Map<String, String> matches,
  required Map<String, Iterable<int>> profileFileIDs,
  required Set<int> personFileIDs,
}) => {
  for (final entry in matches.entries)
    if (entry.value != personID ||
        (profileFileIDs[entry.key]?.isEmpty ?? true) ||
        profileFileIDs[entry.key]!.any(personFileIDs.contains))
      entry.key,
};
