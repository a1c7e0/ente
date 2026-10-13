import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/gateways/files/file_data_gateway.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/filedata/filedata_service.dart";
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/services/filedata/model/response.dart";
import "package:shared_preferences/shared_preferences.dart";

class _MemoryMetadata extends FileDataService {
  Map<String, dynamic> data = {"face": "old", "body": "old", "future": 7};
  int stamp = 10;
  final writes = <int>[];
  _MemoryMetadata(super.prefs, super.gateway);

  @override
  Future<FileDataResponse> getFilesData(
    Set<int> ids, {
    DataType type = DataType.mlData,
  }) => Future.value(
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

  @override
  Future<void> putFileData(EnteFile file, FileDataEntity entity) {
    writes.add(entity.updatedAt!);
    if (writes.length == 1) {
      data["body"] = "another-device";
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
        "future": 7,
      });
    },
  );
}
