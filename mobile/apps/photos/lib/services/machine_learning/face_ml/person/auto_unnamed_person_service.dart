import "package:uuid/uuid.dart";

/// Selects existing, unassigned face clusters that qualify for an unnamed
/// PersonEntity. File IDs are restricted to currently uploaded photos.
class AutoUnnamedPersonService {
  static const int maxCreationsPerClusteringRun = 10;
  static const String _personIDNamespace =
      "de305d54-75b4-431b-adb2-eb6b9e546014";

  static String personEntityID(String clusterID) =>
      const Uuid().v5(_personIDNamespace, "auto-unnamed:$clusterID");

  static List<String> eligibleClusters({
    required int threshold,
    required Map<String, Iterable<String>> clusterToFaceIDs,
    required Set<String> assignedClusterIDs,
    required Set<String> assignedFaceIDs,
    required Set<int> uploadedFileIDs,
  }) {
    if (threshold <= 0) return const [];
    final eligible = <(String, int)>[];
    for (final entry in clusterToFaceIDs.entries) {
      if (assignedClusterIDs.contains(entry.key)) continue;
      final distinctFileIDs = <int>{};
      var containsAssignedFace = false;
      for (final faceID in entry.value) {
        if (assignedFaceIDs.contains(faceID)) containsAssignedFace = true;
        final separator = faceID.indexOf('_');
        if (separator <= 0) continue;
        final fileID = int.tryParse(faceID.substring(0, separator));
        if (fileID != null && uploadedFileIDs.contains(fileID)) {
          distinctFileIDs.add(fileID);
        }
      }
      if (containsAssignedFace) continue;
      if (distinctFileIDs.length >= threshold) {
        eligible.add((entry.key, distinctFileIDs.length));
      }
    }
    eligible.sort((a, b) {
      final bySize = b.$2.compareTo(a.$2);
      return bySize == 0 ? a.$1.compareTo(b.$1) : bySize;
    });
    return eligible
        .take(maxCreationsPerClusteringRun)
        .map((candidate) => candidate.$1)
        .toList(growable: false);
  }
}
