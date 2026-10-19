import "dart:convert";

import "package:photos/models/ml/face/person.dart";

/// Finds duplicate pristine auto-created unnamed people.
///
/// The returned map associates each duplicate's remote ID with the
/// lexicographically smallest remote ID in its exact source group.
class AutoUnnamedDeduplication {
  static Map<String, String> duplicateToCanonical(List<PersonEntity> persons) {
    final candidatesBySource = <String, List<PersonEntity>>{};
    final sourceFacesByKey = <String, Set<String>>{};

    for (final person in persons) {
      final sourceFaces = _pristineSourceFaces(person);
      if (sourceFaces == null) continue;

      final sortedSourceFaces = sourceFaces.toList()..sort();
      final key = jsonEncode(sortedSourceFaces);
      candidatesBySource.putIfAbsent(key, () => <PersonEntity>[]).add(person);
      sourceFacesByKey[key] = sourceFaces;
    }

    final duplicateToCanonical = <String, String>{};
    final sourceKeys = candidatesBySource.keys.toList()..sort();
    for (final sourceKey in sourceKeys) {
      final group = candidatesBySource[sourceKey]!;
      if (group.length < 2) continue;

      final groupRemoteIDs = group.map((person) => person.remoteID).toSet();
      final sourceFaces = sourceFacesByKey[sourceKey]!;
      final isProtected = persons.any((person) {
        if (groupRemoteIDs.contains(person.remoteID)) return false;
        return person.data.assigned.any(
              (cluster) => cluster.faces.any(sourceFaces.contains),
            ) ||
            person.data.rejectedFaceIDs.any(sourceFaces.contains);
      });
      if (isProtected) continue;

      final sortedGroup = group.toList()
        ..sort((a, b) => a.remoteID.compareTo(b.remoteID));
      final canonicalRemoteID = sortedGroup.first.remoteID;
      for (final duplicate in sortedGroup.skip(1)) {
        duplicateToCanonical[duplicate.remoteID] = canonicalRemoteID;
      }
    }

    final sortedDuplicateIDs = duplicateToCanonical.keys.toList()..sort();
    return {
      for (final duplicateID in sortedDuplicateIDs)
        duplicateID: duplicateToCanonical[duplicateID]!,
    };
  }

  static Set<String>? _pristineSourceFaces(PersonEntity person) {
    final data = person.data;
    if (data.autoDuplicateOf != null ||
        !data.isUnnamed ||
        data.name.isNotEmpty ||
        data.isHidden ||
        data.isPinned ||
        data.hideFromMemories ||
        data.avatarFaceID != null ||
        data.birthDate != null ||
        data.email != null ||
        data.userID != null ||
        data.rejectedFaceIDs.isNotEmpty ||
        data.manuallyAssigned.isNotEmpty) {
      return null;
    }

    final sourceFaces = data.autoCreationFaceIDs;
    if (sourceFaces == null ||
        sourceFaces.isEmpty ||
        sourceFaces.any((faceID) => faceID.isEmpty) ||
        sourceFaces.toSet().length != sourceFaces.length) {
      return null;
    }

    if (data.assigned.length != 1) return null;
    final assignedFaces = data.assigned.single.faces;
    if (assignedFaces.isEmpty ||
        assignedFaces.length != sourceFaces.length ||
        !assignedFaces.containsAll(sourceFaces)) {
      return null;
    }

    return sourceFaces.toSet();
  }
}
