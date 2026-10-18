import 'package:ente_accounts/models/user_details.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> detailsMap({
    String? lockerQuotaMode,
    int memberStorageLimit = 800,
    int memberUsage = 400,
    int otherMemberUsage = 200,
    int familyStorage = 1000,
  }) => {
    'email': 'me@example.com',
    'usage': memberUsage,
    'fileCount': 7,
    'storageBonus': 0,
    'sharedCollectionsCount': 0,
    ...?(lockerQuotaMode == null ? null : {'lockerQuotaMode': lockerQuotaMode}),
    'subscription': {
      'productID': 'free',
      'storage': 1000,
      'originalTransactionID': '',
      'paymentProvider': '',
      'expiryTime': 0,
      'price': '',
      'period': '',
    },
    'familyData': {
      'storage': familyStorage,
      'expiryTime': 0,
      'members': [
        {
          'email': 'me@example.com',
          'usage': memberUsage,
          'id': 'me',
          'userID': 1,
          'isAdmin': false,
          'storageLimit': memberStorageLimit,
        },
        {
          'email': 'other@example.com',
          'usage': otherMemberUsage,
          'id': 'other',
          'userID': 2,
          'isAdmin': true,
          'storageLimit': null,
        },
      ],
    },
  };

  test(
    'missing quota mode preserves legacy behavior; shared mode survives cache roundtrip',
    () {
      final legacy = UserDetails.fromMap(detailsMap());
      expect(legacy.usesSharedStorageForLocker, isFalse);
      expect(legacy.getFreeStorage(), 400); // Existing member cap behavior.

      final shared = UserDetails.fromMap(
        detailsMap(lockerQuotaMode: 'sharedStorage'),
      );
      final restored = UserDetails.fromJson(shared.toJson());
      expect(restored.lockerQuotaMode, 'sharedStorage');
      expect(restored.usesSharedStorageForLocker, isTrue);
    },
  );

  test('shared free storage is limited by the member cap', () {
    final details = UserDetails.fromMap(
      detailsMap(
        lockerQuotaMode: 'sharedStorage',
        memberStorageLimit: 450,
        memberUsage: 400,
        otherMemberUsage: 200,
      ),
    );
    expect(details.getFreeStorage(), 50);
  });

  test('shared free storage is limited by remaining family storage', () {
    final details = UserDetails.fromMap(
      detailsMap(
        lockerQuotaMode: 'sharedStorage',
        memberStorageLimit: 800,
        memberUsage: 400,
        otherMemberUsage: 500,
      ),
    );
    expect(details.getFreeStorage(), 100);
  });
  test('unknown quota modes retain the legacy allowance', () {
    final details = UserDetails.fromMap(
      detailsMap(lockerQuotaMode: 'futureMode', otherMemberUsage: 500),
    );
    expect(details.usesSharedStorageForLocker, isFalse);
    expect(details.getFreeStorage(), 400);
  });

  test(
    'shared allowance clamps exhausted family or member storage to zero',
    () {
      for (final values in [
        detailsMap(lockerQuotaMode: 'sharedStorage', otherMemberUsage: 700),
        detailsMap(lockerQuotaMode: 'sharedStorage', memberStorageLimit: 300),
      ]) {
        expect(UserDetails.fromMap(values).getFreeStorage(), 0);
      }
    },
  );

  test('individual shared storage includes the normal storage bonus', () {
    final values = detailsMap(lockerQuotaMode: 'sharedStorage')
      ..remove('familyData')
      ..['storageBonus'] = 100;
    final details = UserDetails.fromMap(values);
    expect(details.getTotalStorage(), 1100);
    expect(details.getFreeStorage(), 700);
  });
}
