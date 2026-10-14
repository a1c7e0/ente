import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/face/face.dart";

const _faceKey = 'face';
const faceEmbeddingModel = 'mobilefacenet-portable-v1';
const faceDetectionModel = 'yolov5s-face-v1';
const _clipKey = 'clip';

enum DataType {
  mlData('mldata');

  final String value;
  const DataType(this.value);

  static DataType fromString(String type) {
    return DataType.values.firstWhere(
      (e) => e.value == type,
      orElse: () {
        throw Exception('Unknown type: $type');
      },
    );
  }

  String toJson() => value;
  static DataType fromJson(String json) => DataType.fromString(json);
}

class FileDataEntity {
  int? updatedAt;
  final int fileID;
  final Map<String, dynamic> remoteRawData;
  final DataType type;

  FileDataEntity(this.fileID, this.remoteRawData, this.type);

  void validate() {
    if (type == DataType.mlData) {
      // Independent body metadata can exist without legacy subtypes.
      // Readers already treat absent subtypes as not indexed.
      if (bodyIndex != null) return;
      if (remoteRawData[_faceKey] == null) {
        throw Exception('Face embedding is null');
      }
      if (remoteRawData[_clipKey] == null) {
        throw Exception('Clip embedding is null');
      }
    } else {
      throw Exception('Invalid type ${type.value}');
    }
  }

  factory FileDataEntity.fromRemote(
    int fileID,
    String type,
    Map<String, dynamic> json,
  ) {
    return FileDataEntity(fileID, json, DataType.fromString(type));
  }

  static FileDataEntity empty(int fileID, DataType type) {
    final Map<String, dynamic> json = {};
    return FileDataEntity(fileID, json, type);
  }

  void putFace(RemoteFaceEmbedding faceEmbedding) {
    assert(type == DataType.mlData, 'Invalid type ${type.value}');
    remoteRawData[_faceKey] = faceEmbedding.toJson();
  }

  void putClip(RemoteClipEmbedding clipEmbedding) {
    assert(type == DataType.mlData, 'Invalid type ${type.value}');
    remoteRawData[_clipKey] = clipEmbedding.toJson();
  }

  BodyIndex? get bodyIndex => BodyIndex.tryParse(remoteRawData["body"]);

  bool get hasUnsupportedBody {
    final raw = remoteRawData["body"];
    if (raw is! Map<String, dynamic> || raw["version"] is! num) return false;
    final version = raw["version"] as num;
    return version > bodyMlVersion ||
        (version == bodyMlVersion &&
            raw["model"] is String &&
            raw["model"] != bodyModel);
  }

  void putBody(BodyIndex index) {
    remoteRawData["body"] = index.toJson();
  }

  RemoteFaceEmbedding? get faceEmbedding => remoteRawData[_faceKey] != null
      ? RemoteFaceEmbedding.fromJson(
          remoteRawData[_faceKey] as Map<String, dynamic>,
        )
      : null;

  RemoteClipEmbedding? getClipEmbeddingIfCompatible(int minClipMlVersion) {
    final clipData = remoteRawData[_clipKey];
    if (clipData == null) return null;

    final clipEmbedding = RemoteClipEmbedding.fromJson(
      clipData as Map<String, dynamic>,
    );
    return clipEmbedding.version >= minClipMlVersion ? clipEmbedding : null;
  }
}

class RemoteFaceEmbedding {
  final List<Face> faces;
  final int version;
  final String client;
  final int height;
  final int width;
  final String model;
  final String detectorModel;
  final Map<String, dynamic> raw;

  // Bits are defined in ml_versions.dart; absent on the wire means legacy 0.
  final int flags;

  RemoteFaceEmbedding(
    this.faces,
    this.version, {
    required this.client,
    required this.height,
    required this.width,
    this.flags = 0,
    this.model = faceEmbeddingModel,
    this.detectorModel = faceDetectionModel,
    this.raw = const {},
  });

  Map<String, dynamic> toJson() => {
    ...raw,
    'model': model,
    'detectorModel': detectorModel,
    'faces': faces.map((x) => x.toJson()).toList(),
    'version': version,
    'client': client,
    'height': height,
    'width': width,
    if (flags != 0) 'flags': flags,
  };

  factory RemoteFaceEmbedding.fromJson(Map<String, dynamic> json) {
    return RemoteFaceEmbedding(
      List<Face>.from(
        json['faces'].map((x) => Face.fromJson(x as Map<String, dynamic>)),
      ),
      json['version'] as int,
      client: json['client'] as String,
      height: json['height'] as int,
      width: json['width'] as int,
      flags: (json['flags'] as int?) ?? 0,
      model: json['model'] as String? ?? faceEmbeddingModel,
      detectorModel: json['detectorModel'] as String? ?? faceDetectionModel,
      raw: json,
    );
  }
}

class RemoteClipEmbedding {
  final int version;
  final String client;
  final List<double> embedding;

  // Bits are defined in ml_versions.dart; absent on the wire means legacy 0.
  final int flags;

  RemoteClipEmbedding(
    this.embedding, {
    required this.version,
    required this.client,
    this.flags = 0,
  });

  Map<String, dynamic> toJson() => {
    'embedding': embedding,
    'version': version,
    'client': client,
    if (flags != 0) 'flags': flags,
  };

  factory RemoteClipEmbedding.fromJson(Map<String, dynamic> json) {
    return RemoteClipEmbedding(
      parseAsDoubleList(json['embedding'] as List),
      version: json['version'] as int,
      client: json['client'] as String,
      flags: (json['flags'] as int?) ?? 0,
    );
  }
}

class FDStatus {
  final int fileID;
  final int userID;
  final String type;
  final bool isDeleted;
  final int size;
  final int updatedAt;
  final String? objectID;
  final String? objectNonce;
  FDStatus({
    required this.fileID,
    required this.userID,
    required this.type,
    required this.size,
    required this.updatedAt,
    this.isDeleted = false,
    this.objectID,
    this.objectNonce,
  });

  factory FDStatus.fromJson(Map<String, dynamic> json) {
    return FDStatus(
      fileID: json['fileID'] as int,
      userID: json['userID'] as int,
      type: json['type'] as String,
      isDeleted: json['isDeleted'] as bool? ?? false,
      size: json['size'] as int,
      objectID: json['objectID'] as String?,
      objectNonce: json['objectNonce'] as String?,
      updatedAt: json['updatedAt'] as int,
    );
  }
}

class PreviewInfo {
  final String objectId;
  final int objectSize;
  String? nonce;
  PreviewInfo({required this.objectId, required this.objectSize, this.nonce});
}
