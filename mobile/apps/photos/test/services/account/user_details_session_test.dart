import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/account/user_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late Dio dio;
  Completer<Response<dynamic>>? response;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          handler.resolve(await response!.future);
        },
      ),
    );
    ServiceLocator.instance.init(
      preferences,
      dio,
      dio,
      Dio(),
      PackageInfo(
        appName: 'Photos',
        packageName: 'photos',
        version: '1.0.0',
        buildNumber: '1',
      ),
    );
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final directory = Directory.systemTemp
        .createTempSync('account-session')
        .path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => directory);
    const backupExclusion = MethodChannel('backup_exclusion');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backupExclusion, (call) async => null);
    const secureStorage = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    await Configuration.instance.init(preferences);
    await UserService.instance.init();
  });

  setUp(() async {
    await preferences.clear();
    await preferences.setString(UserService.keyUserDetails, 'old-cache');
    await preferences.setBool(UserService.kIsEmailMFAEnabled, false);
    await preferences.setBool(UserService.keyHasEnabledTwoFactor, false);
    await preferences.setString(Configuration.emailKey, 'a@example.com');
    await preferences.setInt(Configuration.userIDKey, 1);
    await Configuration.instance.setToken('token-a');
    await Configuration.instance.setUserID(1);
    await Configuration.instance.setEmail('a@example.com');
    UserService.instance.emailValueNotifier.value = 'a@example.com';
  });

  test('drops stale details after switching accounts', () async {
    response = Completer<Response<dynamic>>();
    final request = UserService.instance.getUserDetailsV2();
    await Configuration.instance.setUserID(2);
    await Configuration.instance.setToken('token-b');
    response!.complete(_response('stale@example.com'));

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
    expect(preferences.getBool(UserService.kIsEmailMFAEnabled), false);
    expect(preferences.getBool(UserService.keyHasEnabledTwoFactor), false);
    expect(Configuration.instance.getEmail(), 'a@example.com');
    expect(UserService.instance.emailValueNotifier.value, 'a@example.com');
  });

  test('checks token when the same user signs in again', () async {
    response = Completer<Response<dynamic>>();
    final request = UserService.instance.getUserDetailsV2();
    await Configuration.instance.setToken('token-a-new-session');
    response!.complete(_response('stale@example.com'));

    await expectLater(request, throwsA(isA<DioException>()));
    expect(preferences.getString(UserService.keyUserDetails), 'old-cache');
  });

  test(
    'caches current response and leaves shouldCache false untouched',
    () async {
      response = Completer<Response<dynamic>>();
      final request = UserService.instance.getUserDetailsV2();
      response!.complete(_response('a@example.com'));
      expect((await request).email, 'a@example.com');
      expect(
        preferences.getString(UserService.keyUserDetails),
        isNot('old-cache'),
      );

      await preferences.setString(UserService.keyUserDetails, 'old-cache');
      response = Completer<Response<dynamic>>();
      final uncached = UserService.instance.getUserDetailsV2(
        shouldCache: false,
      );
      response!.complete(_response('a@example.com'));
      expect((await uncached).email, 'a@example.com');
      expect(preferences.getString(UserService.keyUserDetails), 'old-cache');
    },
  );
}

Response<dynamic> _response(String email) => Response(
  requestOptions: RequestOptions(path: '/users/details/v2'),
  data: {
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
    'profileData': {
      'canDisableEmailMFA': true,
      'isEmailMFAEnabled': true,
      'isTwoFactorEnabled': true,
    },
  },
);
