import "package:flutter_test/flutter_test.dart";
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/models/ml/body.dart";

void main() {
  test(
    "legacy face metadata defaults to current models and preserves extensions",
    () {
      final face = RemoteFaceEmbedding.fromJson({
        "faces": [],
        "version": 1,
        "client": "legacy",
        "width": 100,
        "height": 100,
        "future": 7,
      });
      expect(face.model, faceEmbeddingModel);
      expect(face.detectorModel, faceDetectionModel);
      expect(face.toJson()["future"], 7);
      expect(face.toJson()["model"], faceEmbeddingModel);
    },
  );
  test(
    "independent body metadata remains readable through optional legacy subtypes",
    () {
      final entity = FileDataEntity.empty(1, DataType.mlData)
        ..putBody(BodyIndex(100, 100, []));
      entity.validate();
      expect(entity.faceEmbedding, isNull);
      expect(entity.getClipEmbeddingIfCompatible(1), isNull);
      expect(entity.bodyIndex!.detections, isEmpty);
    },
  );
  test("face and CLIP updates preserve unknown body and future metadata", () {
    final body = {
      "version": 99,
      "future": {"value": true},
    };
    final entity = FileDataEntity.fromRemote(1, "mldata", {
      "body": body,
      "anotherSubtype": {"value": 7},
    });
    entity.putFace(
      RemoteFaceEmbedding([], 1, client: "test", height: 100, width: 100),
    );
    entity.putClip(RemoteClipEmbedding([0.1], version: 1, client: "test"));
    entity.validate();
    expect(entity.remoteRawData["body"], body);
    expect(entity.remoteRawData["anotherSubtype"], {"value": 7});
    expect(entity.faceEmbedding!.faces, isEmpty);
    expect(entity.bodyIndex, isNull);
    expect(entity.getClipEmbeddingIfCompatible(1)!.embedding, [0.1]);
  });
}
