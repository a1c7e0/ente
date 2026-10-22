import 'dart:async';

import 'package:dio/dio.dart';
import 'package:ente_accounts/services/user_service.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late _TestConfiguration config;
  late Dio dio;
  late UserService service;
  Completer<Response<dynamic>>? response;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      BaseConfiguration.userIDKey: 1,
      BaseConfiguration.tokenKey: 'token-a',
      BaseConfiguration.emailKey: 'a@example.com',
      UserService.keyUserDetails: 'old-cache',
      UserService.kIsEmailMFAEnabled: false,
      UserService.kCanDisableEmailMFA: false,
    });
    preferences = await SharedPreferences.getInstance();
    config = _TestConfiguration();
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final current = response!;
          handler.resolve(await current.future);
        },
      ),
    );
    response = Completer<Response<dynamic>>();
    service = UserService.test(
      enteDio: dio,
      config: config,
      preferences: preferences,
    );
  });

  test(
    'rejects a response after logout and account switch without writes',
    () async {
      final request = service.getUserDetailsV2();
      config.userId = 2;
      config.token = 'token-b';
      response!.complete(
        Response(
          requestOptions: RequestOptions(path: '/users/details/v2'),
          data: _userDetails('stale@example.com'),
        ),
      );

      await expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(preferences.getString(UserService.keyUserDetails), 'old-cache');
      expect(
        preferences.getString(BaseConfiguration.emailKey),
        'a@example.com',
      );
      expect(config.email, 'a@example.com');
    },
  );

  test('rejects same user logged in again with a different token', () async {
    final request = service.getUserDetailsV2();
    config.token = 'token-a-new-session';
    response!.complete(
      Response(
        requestOptions: RequestOptions(path: '/users/details/v2'),
        data: _userDetails('stale@example.com'),
      ),
    );

    await expectLater(request, throwsA(isA<DioException>()));
    expect(preferences.getString(UserService.keyUserDetails), 'old-cache');
  });

  test(
    'does not publish the old email after the session changes during save',
    () async {
      final emailSave = Completer<void>();
      final emailSaveStarted = Completer<void>();
      config.emailSaveGate = emailSave;
      config.emailSaveStarted = emailSaveStarted;
      final request = service.getUserDetailsV2();
      response!.complete(
        Response(
          requestOptions: RequestOptions(path: '/users/details/v2'),
          data: _userDetails('stale@example.com'),
        ),
      );
      await emailSaveStarted.future;
      config.token = 'token-b';
      emailSave.complete();

      await expectLater(request, throwsA(isA<DioException>()));
      expect(service.emailValueNotifier.value, 'a@example.com');
    },
  );

  test('caches a current response and does not cache when requested', () async {
    final request = service.getUserDetailsV2();
    response!.complete(
      Response(
        requestOptions: RequestOptions(path: '/users/details/v2'),
        data: _userDetails('a@example.com'),
      ),
    );
    expect((await request).email, 'a@example.com');
    expect(
      preferences.getString(UserService.keyUserDetails),
      isNot('old-cache'),
    );

    await preferences.setString(UserService.keyUserDetails, 'old-cache');
    response = Completer<Response<dynamic>>();
    final uncached = service.getUserDetailsV2(shouldCache: false);
    response!.complete(
      Response(
        requestOptions: RequestOptions(path: '/users/details/v2'),
        data: _userDetails('a@example.com'),
      ),
    );
    expect((await uncached).email, 'a@example.com');
    expect(preferences.getString(UserService.keyUserDetails), 'old-cache');
  });
}

Map<String, dynamic> _userDetails(String email) => {
  'email': email,
  'usage': 0,
  'fileCount': 0,
  'storageBonus': 0,
  'sharedCollectionsCount': 0,
  'subscription': {
    'productID': 'free',
    'storage': 0,
    'originalTransactionID': '',
    'paymentProvider': '',
    'expiryTime': 0,
    'price': '',
    'period': '',
  },
};

class _TestConfiguration extends BaseConfiguration {
  int? userId = 1;
  String? token = 'token-a';
  String? email = 'a@example.com';
  Completer<void>? emailSaveGate;
  Completer<void>? emailSaveStarted;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  int? getUserID() => userId;

  @override
  String? getToken() => token;

  @override
  String? getEmail() => email;

  @override
  Future<void> setEmail(String value) async {
    email = value;
    if (emailSaveStarted != null && !emailSaveStarted!.isCompleted) {
      emailSaveStarted!.complete();
    }
    await emailSaveGate?.future;
  }
}
