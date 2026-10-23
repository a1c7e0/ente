import "dart:convert";

import "package:photos/models/ml/body.dart";

/// Only user edits are queued. Generated boxes, vectors and unknown metadata
/// remain in the ML index and are never copied into the feedback queue.
class BodyFeedbackPatch {
  BodyFeedbackPatch(this.bodies, this.manual);
  final Map<String, dynamic> bodies;
  final Map<String, dynamic> manual;

  factory BodyFeedbackPatch.fromJson(Map<String, dynamic> json) =>
      BodyFeedbackPatch(
        Map<String, dynamic>.from(json["bodies"] as Map),
        Map<String, dynamic>.from(json["manual"] as Map),
      );

  Map<String, dynamic> toJson() => {"bodies": bodies, "manual": manual};

  BodyFeedbackPatch merge(BodyFeedbackPatch newer) {
    final merged = Map<String, dynamic>.from(bodies);
    for (final entry in newer.bodies.entries) {
      final previous = Map<String, dynamic>.from(
        merged[entry.key] as Map? ?? {},
      );
      final next = Map<String, dynamic>.from(entry.value as Map);
      merged[entry.key] = {
        ...previous,
        ...next,
        if (previous.containsKey("expectedGroup"))
          "expectedGroup": previous["expectedGroup"],
        "expectedGroups": {
          ...?previous["expectedGroups"] as List?,
          if (previous.containsKey("expectedGroup")) previous["expectedGroup"],
          if (next.containsKey("expectedGroup")) next["expectedGroup"],
        }.toList(),
        "decisions": {
          ...?previous["decisions"] as Map?,
          ...?next["decisions"] as Map?,
        },
      };
    }
    return BodyFeedbackPatch(merged, {...manual, ...newer.manual});
  }

  void apply(BodyIndex index, {bool checkGroup = false}) {
    for (final entry in bodies.entries) {
      final body = index.detections.firstWhere((d) => d.bodyID == entry.key);
      final patch = entry.value as Map;
      if (checkGroup &&
          patch.containsKey("expectedGroup") &&
          body.groupID != patch["expectedGroup"] &&
          !((patch["expectedGroups"] as List?)?.contains(body.groupID) ??
              false) &&
          !(patch.containsKey("groupID") && body.groupID == patch["groupID"])) {
        throw StateError("Body grouping changed; feedback remains pending");
      }
      if (patch.containsKey("groupID")) {
        if (patch["groupID"] == null) {
          body.raw.remove("groupID");
        } else {
          body.raw["groupID"] = patch["groupID"];
        }
      }
      if (patch.containsKey("rejectedAnchorFaceIDs")) {
        body.raw["rejectedAnchorFaceIDs"] = patch["rejectedAnchorFaceIDs"];
      }
      for (final decision in (patch["decisions"] as Map).entries) {
        if (decision.value == null) {
          body.decisions.remove(decision.key);
        } else {
          body.decisions[decision.key as String] = decision.value;
        }
      }
    }
  }

  static BodyFeedbackPatch between(BodyIndex before, BodyIndex after) {
    final bodies = <String, dynamic>{};
    final manual = <String, dynamic>{};
    for (final body in after.detections) {
      final old = before.detections.firstWhere((d) => d.bodyID == body.bodyID);
      final decisions = <String, dynamic>{};
      for (final person in {...old.decisions.keys, ...body.decisions.keys}) {
        final previous = old.decisions[person];
        final next = body.decisions[person];
        if (jsonEncode(previous) == jsonEncode(next)) continue;
        decisions[person] = next;
        if (next is Map &&
            next["status"] == "accepted" &&
            next["addedManual"] == true) {
          manual[person] = true;
        } else if (previous is Map &&
            previous["status"] == "accepted" &&
            previous["addedManual"] == true) {
          final retained = after.detections.any((d) {
            final decision = d.decisions[person];
            return decision is Map && decision["status"] == "accepted";
          });
          if (!retained) manual[person] = false;
        }
      }
      final groupChanged = old.groupID != body.groupID;
      final anchorsChanged =
          jsonEncode(old.rejectedAnchorFaceIDs) !=
          jsonEncode(body.rejectedAnchorFaceIDs);
      if (decisions.isEmpty && !groupChanged && !anchorsChanged) continue;
      bodies[body.bodyID] = {
        "decisions": decisions,
        "expectedGroup": old.groupID,
        if (groupChanged) "groupID": body.groupID,
        if (anchorsChanged) "rejectedAnchorFaceIDs": body.rejectedAnchorFaceIDs,
      };
    }
    return BodyFeedbackPatch(bodies, manual);
  }
}
