import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/gateways/files/file_data_gateway.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/filedata/filedata_service.dart";
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/services/filedata/model/response.dart";
import "package:shared_preferences/shared_preferences.dart";

const _clip = {
  "version": 1,
  "client": "test",
  "embedding": [0.1],
};

class _MemoryMetadata extends FileDataService {
  Map<String, dynamic> data = {
    "face": "old",
    "body": "old",
    "clip": _clip,
    "future": 7,
  };
  int stamp = 10;
  final writes = <int>[];
  int reads = 0;
  bool conflictFirstWrite = true;
  String conflictingSubtype = "body";
  _MemoryMetadata(super.prefs, super.gateway);

  @override
  Future<FileDataResponse> getFilesData(
    Set<int> ids, {
    DataType type = DataType.mlData,
  }) {
    reads++;
    return Future.value(
      FileDataResponse(
        {
          1: FileDataEntity.fromRemote(
            1,
            "mldata",
            jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
          )..updatedAt = stamp,
        },
        fetchErrorFileIDs: {},
        pendingIndexFileIDs: {},
      ),
    );
  }

  @override
  Future<void> putFileData(EnteFile file, FileDataEntity entity) {
    writes.add(entity.updatedAt!);
    if (conflictFirstWrite && writes.length == 1) {
      data[conflictingSubtype] = "another-device";
      stamp = 20;
      final request = RequestOptions(path: "/files/data");
      return Future.error(
        DioException(
          requestOptions: request,
          response: Response(requestOptions: request, statusCode: 409),
        ),
      );
    }
    data = entity.remoteRawData;
    return Future.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    "face writes share conflict merging and retain newer body review",
    () async {
      SharedPreferences.setMockInitialValues({});
      final service = _MemoryMetadata(
        await SharedPreferences.getInstance(),
        FileDataGateway(Dio()),
      );
      final file = EnteFile()..uploadedFileID = 1;
      await service.updateFileData(file, (latest) {
        latest.remoteRawData["face"] = "new";
        return true;
      });
      expect(service.writes, [10, 20]);
      expect(service.data, {
        "face": "new",
        "body": "another-device",
        "clip": _clip,
        "future": 7,
      });
    },
  );
  test(
    "batch-fetched metadata avoids an extra read on a successful update",
    () async {
      SharedPreferences.setMockInitialValues({});
      final service = _MemoryMetadata(
        await SharedPreferences.getInstance(),
        FileDataGateway(Dio()),
      )..conflictFirstWrite = false;
      final snapshot = (await service.getFilesData({1})).data[1]!;
      await service.updateFileData(EnteFile()..uploadedFileID = 1, (latest) {
        latest.remoteRawData["body"] = "reviewed";
        return true;
      }, initialData: snapshot);
      expect(service.reads, 1);
      expect(service.writes, [10]);
      expect(service.data, {
        "face": "old",
        "body": "reviewed",
        "clip": _clip,
        "future": 7,
      });
    },
  );

  test(
    "a conflicting batch snapshot refetches and preserves another device's update",
    () async {
      SharedPreferences.setMockInitialValues({});
      final service = _MemoryMetadata(
        await SharedPreferences.getInstance(),
        FileDataGateway(Dio()),
      )..conflictingSubtype = "face";
      final snapshot = (await service.getFilesData({1})).data[1]!;
      await service.updateFileData(EnteFile()..uploadedFileID = 1, (latest) {
        latest.remoteRawData["body"] = "reviewed";
        return true;
      }, initialData: snapshot);
      expect(service.reads, 2);
      expect(service.writes, [10, 20]);
      expect(service.data, {
        "face": "another-device",
        "body": "reviewed",
        "clip": _clip,
        "future": 7,
      });
    },
  );

  test("a snapshot for another file is rejected before any request", () async {
    SharedPreferences.setMockInitialValues({});
    final service = _MemoryMetadata(
      await SharedPreferences.getInstance(),
      FileDataGateway(Dio()),
    );
    await expectLater(
      service.updateFileData(
        EnteFile()..uploadedFileID = 1,
        (_) => true,
        initialData: FileDataEntity.fromRemote(2, "mldata", {"future": 7})
          ..updatedAt = 10,
      ),
      throwsArgumentError,
    );
    expect(service.reads, 0);
    expect(service.writes, isEmpty);
  });
}
