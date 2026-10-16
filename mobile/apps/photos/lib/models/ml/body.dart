import "dart:math" as math;

import "package:photos/models/ml/face/box.dart";

const bodyMlVersion = 1;
const bodyModel = "osnet-ain-x1.0-msmt17-v1";
const bodyEmbeddingPrecision = "decimal4-v1";

double _compactEmbeddingValue(double value) => value.isFinite && value != 0
    ? double.parse(value.toStringAsPrecision(4))
    : value;

List<double> compactBodyEmbedding(Iterable<double> values) =>
    values.map(_compactEmbeddingValue).toList(growable: false);

class BodyDetection {
  final String bodyID;
  final FaceBox box;
  final double score;
  final List<double> embedding;
  final String? linkedFaceID;
  final Map<String, dynamic> decisions;
  final Map<String, dynamic> raw;
  String? get groupID => raw["groupID"] as String?;
  List<String> get rejectedAnchorFaceIDs =>
      (raw["rejectedAnchorFaceIDs"] as List?)?.cast<String>() ?? const [];

  void bindReviewGroup(String reference) {
    final id = reference.startsWith("body-group:")
        ? reference
        : "body-group:${reference.substring(5)}";
    if (groupID != null && groupID != id) {
      throw StateError("Body grouping changed; reload the review");
    }
    raw["groupID"] = id;
  }

  BodyDetection({
    required this.bodyID,
    required this.box,
    required this.score,
    required List<double> embedding,
    this.linkedFaceID,
    this.decisions = const {},
    this.raw = const {},
  }) : embedding = compactBodyEmbedding(embedding);

  factory BodyDetection.fromJson(Map<String, dynamic> json) {
    final embedding = (json["embedding"] as List)
        .map((e) => (e as num).toDouble())
        .toList();
    final box = FaceBox.fromJson(json["box"] as Map<String, dynamic>);
    final bodyID = json["bodyID"] as String;
    final groupID = json["groupID"];
    final score = (json["score"] as num).toDouble();
    final decisions = Map<String, dynamic>.from(
      json["decisions"] as Map? ?? {},
    );
    final rejectedAnchors = json["rejectedAnchorFaceIDs"];
    if (!bodyID.startsWith("body:") ||
        (groupID != null &&
            (groupID is! String || !groupID.startsWith("body-group:"))) ||
        !score.isFinite ||
        score < 0 ||
        score > 1 ||
        (rejectedAnchors != null &&
            (rejectedAnchors is! List ||
                rejectedAnchors.any((id) => id is! String))) ||
        decisions.values.any(
          (d) =>
              d is! Map ||
              (d["status"] != "accepted" && d["status"] != "rejected"),
        ) ||
        embedding.length != 512 ||
        embedding.any((v) => !v.isFinite) ||
        embedding.fold<double>(0, (s, v) => s + v * v) < 1e-6 ||
        [
          box.x,
          box.y,
          box.width,
          box.height,
        ].any((v) => !v.isFinite || v < 0 || v > 1) ||
        box.width == 0 ||
        box.height == 0) {
      throw const FormatException("Invalid body detection");
    }
    return BodyDetection(
      bodyID: bodyID,
      box: box,
      score: score,
      embedding: embedding,
      linkedFaceID: json["linkedFaceID"] as String?,
      decisions: decisions,
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => {
    ...raw,
    "bodyID": bodyID,
    "box": box.toJson(),
    "score": score,
    "embedding": embedding,
    "linkedFaceID": linkedFaceID,
    "decisions": decisions,
  };
}

class BodyIndex {
  final int version;
  final int width;
  final int height;
  final List<BodyDetection> detections;
  final Map<String, dynamic> raw;

  BodyIndex(this.width, this.height, this.detections)
    : version = bodyMlVersion,
      raw = {};

  BodyIndex._(this.version, this.width, this.height, this.detections, this.raw);

  static BodyIndex? tryParse(dynamic value) {
    try {
      if (value is! Map<String, dynamic> ||
          value["version"] != bodyMlVersion ||
          value["model"] != bodyModel) {
        return null;
      }
      final width = value["width"] as int;
      final height = value["height"] as int;
      if (width <= 0 || height <= 0) return null;
      return BodyIndex._(
        bodyMlVersion,
        width,
        height,
        (value["detections"] as List)
            .map((d) => BodyDetection.fromJson(d as Map<String, dynamic>))
            .toList(),
        value,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    ...raw,
    "version": version,
    "model": bodyModel,
    "client": raw["client"] is String ? raw["client"] : "ente",
    "width": width,
    "height": height,
    "detections": detections.map((d) => d.toJson()).toList(),
    "embeddingPrecision": bodyEmbeddingPrecision,
  };
}

Map<String, dynamic> clearBodyReviewData(Map<String, dynamic> body) {
  final cleaned = Map<String, dynamic>.from(body);
  final detections = body["detections"];
  if (detections is! List) return cleaned;

  cleaned["detections"] = detections.map((detection) {
    if (detection is! Map) return detection;
    final cleanedDetection = Map<String, dynamic>.from(detection);
    cleanedDetection.remove("groupID");
    cleanedDetection.remove("rejectedAnchorFaceIDs");
    cleanedDetection["decisions"] = <String, dynamic>{};
    return cleanedDetection;
  }).toList();
  return BodyIndex.tryParse(cleaned)?.toJson() ?? cleaned;
}

double bodyCosine(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return -1;
  double dot = 0, aa = 0, bb = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    aa += a[i] * a[i];
    bb += b[i] * b[i];
  }
  return aa > 0 && bb > 0 ? dot / math.sqrt(aa * bb) : -1;
}

class BodyMatch {
  final int fileID;
  final BodyDetection detection;
  final String personID;
  final double similarity;
  final double margin;
  const BodyMatch(
    this.fileID,
    this.detection,
    this.personID,
    this.similarity,
    this.margin,
  );
  bool get automatic => similarity >= 0.74 && margin >= 0.05;
}

bool isBodyReference(String id) =>
    id.startsWith("body:") || id.startsWith("body-group:");

class BodyGroup {
  final String id;
  final String personID;
  final List<BodyMatch> matches;
  BodyGroup(this.id, this.personID, this.matches);
}

List<BodyGroup> groupBodyMatches(
  List<BodyMatch> matches,
  Map<int, int> times, {
  double threshold = 0.8,
}) {
  final groups = <BodyGroup>[];
  final ordered = matches.toList()
    ..sort((a, b) => a.detection.bodyID.compareTo(b.detection.bodyID));
  for (final match in ordered) {
    final partition = match.detection.groupID;
    BodyGroup? target;
    for (final group in groups) {
      if (group.personID != match.personID ||
          (partition != null
              ? group.id != partition
              : group.matches.first.detection.groupID != null)) {
        continue;
      }
      if (group.matches.every(
        (m) =>
            m.fileID != match.fileID &&
            (partition != null ||
                ((times[m.fileID] ?? 0) > 0 &&
                    (times[match.fileID] ?? 0) > 0 &&
                    (times[m.fileID]! - times[match.fileID]!).abs() <=
                        const Duration(hours: 3).inMicroseconds &&
                    bodyCosine(
                          m.detection.embedding,
                          match.detection.embedding,
                        ) >=
                        threshold)),
      )) {
        target = group;
        break;
      }
    }
    if (target != null) {
      target.matches.add(match);
    } else {
      groups.add(
        BodyGroup(
          partition ?? "body-group:${match.detection.bodyID.substring(5)}",
          match.personID,
          [match],
        ),
      );
    }
  }
  return groups;
}

List<BodyMatch> matchBodyDetections(
  Map<int, BodyIndex> indices,
  Map<int, int> times,
  Map<String, String> facePersons,
) {
  final anchors = <(int, BodyDetection, String)>[];
  final occupancy = <int, Set<String>>{};
  for (final entry in facePersons.entries) {
    final id = int.tryParse(entry.key.split("_").first);
    if (id != null) occupancy.putIfAbsent(id, () => {}).add(entry.value);
  }

  for (final entry in indices.entries) {
    if (!times.containsKey(entry.key)) continue;
    for (final body in entry.value.detections) {
      final pid = facePersons[body.linkedFaceID];
      if (pid != null) {
        anchors.add((entry.key, body, pid));
        occupancy.putIfAbsent(entry.key, () => {}).add(pid);
      }
    }
  }
  final matches = <BodyMatch>[];
  for (final entry in indices.entries) {
    final time = times[entry.key];
    if (time == null || time <= 0) continue;
    for (final body in entry.value.detections) {
      if (body.decisions.values.any(
        (d) => d is Map && d["status"] == "accepted",
      )) {
        continue;
      }
      if (facePersons.containsKey(body.linkedFaceID)) continue;
      final scores = <String, double>{};
      final rejectedPersons = {
        for (final faceID in body.rejectedAnchorFaceIDs)
          if (facePersons.containsKey(faceID)) facePersons[faceID]!,
      };
      for (final anchor in anchors) {
        final anchorTime = times[anchor.$1];
        if (anchorTime == null ||
            anchorTime <= 0 ||
            (time - anchorTime).abs() >
                const Duration(hours: 3).inMicroseconds ||
            occupancy[entry.key]?.contains(anchor.$3) == true) {
          continue;
        }
        final s = bodyCosine(body.embedding, anchor.$2.embedding);
        if (s > (scores[anchor.$3] ?? -1)) scores[anchor.$3] = s;
      }
      final ranked = scores.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (ranked.isEmpty || ranked.first.value < 0.63) continue;
      final best = ranked.first;
      if (body.decisions.containsKey(best.key) ||
          rejectedPersons.contains(best.key)) {
        continue;
      }
      matches.add(
        BodyMatch(
          entry.key,
          body,
          best.key,
          best.value,
          best.value - (ranked.length > 1 ? ranked[1].value : -1),
        ),
      );
    }
  }
  matches.sort((a, b) => b.similarity.compareTo(a.similarity));
  // Stronger detections reserve the person in a group photo first.
  final reserved = <int, Set<String>>{};
  return matches
      .where((m) => reserved.putIfAbsent(m.fileID, () => {}).add(m.personID))
      .toList();
}
