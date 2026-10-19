import "dart:typed_data";

import "package:ml_linalg/linalg.dart";
import "package:photos/generated/protos/ente/common/vector.pb.dart";

/// Finds a tentative review target for pose-only singletons. The caller adds
/// these directly to manual review; this never changes face assignments.
Map<String, (String, double)> profileReviewMatches(Map<String, dynamic> args) {
  final profileClusterIDs = args["profileClusterIDs"] as Set<String>;
  final targetPersonIDs = args["targetPersonIDs"] as Set<String>;
  final personToClusterIDs =
      args["personToClusterIDs"] as Map<String, Set<String>>;
  final clusterCounts = args["clusterCounts"] as Map<String, int>;
  final summaries = args["summaries"] as Map<String, (Uint8List, int)>;
  const maxReferenceDistance = 0.65;
  const personDistanceMargin = 0.15;

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

  final matches = <String, (String, double)>{};
  for (final clusterID in profileClusterIDs) {
    if (clusterCounts[clusterID] != 1 ||
        assignedClusterIDs.contains(clusterID)) {
      continue;
    }
    final candidate = readCentroid(clusterID);
    if (candidate == null) continue;

    String? nearestPerson;
    var nearestDistance = maxReferenceDistance;
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
    if (!ambiguous) matches[clusterID] = (nearestPerson, nearestDistance);
  }
  return matches;
}

/// Appends qualified profile candidates after normal suggestions so the
/// existing review UI can present them without applying its stricter mean or
/// median grouping thresholds a second time.
List<(String, double, bool)> mergeProfileReviewSuggestions({
  required List<(String, double, bool)> suggestions,
  required String personID,
  required Map<String, (String, double)> profileMatches,
}) {
  final result = [...suggestions];
  final included = suggestions.map((suggestion) => suggestion.$1).toSet();
  for (final entry in profileMatches.entries) {
    if (entry.value.$1 == personID && included.add(entry.key)) {
      result.add((entry.key, entry.value.$2, false));
    }
  }
  return result;
}

/// Extra exclusions apply only to the newly admitted profile candidates.
Set<String> profileReviewExclusions({
  required String personID,
  required Map<String, (String, double)> matches,
  required Map<String, Iterable<int>> profileFileIDs,
  required Set<int> personFileIDs,
}) => {
  for (final entry in matches.entries)
    if (entry.value.$1 != personID ||
        (profileFileIDs[entry.key]?.isEmpty ?? true) ||
        profileFileIDs[entry.key]!.any(personFileIDs.contains))
      entry.key,
};
