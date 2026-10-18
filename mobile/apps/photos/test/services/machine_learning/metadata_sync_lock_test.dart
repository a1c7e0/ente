import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/services/machine_learning/ml_process_lock.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel("io.ente.photos.platform/process_lock");
  final calls = <String>[];
  var nativeLockHeld = false;

  setUp(() {
    calls.clear();
    nativeLockHeld = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map<dynamic, dynamic>;
          switch (call.method) {
            case "processLock.tryAcquire":
              final operation = args["operation"] as String;
              calls.add("acquire:$operation");
              if (nativeLockHeld) return false;
              nativeLockHeld = true;
              return true;
            case "processLock.release":
              calls.add("release");
              nativeLockHeld = false;
              return true;
            default:
              throw StateError("Unexpected process-lock call ${call.method}");
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    "metadata hydration skips a busy funnel and retries after release",
    () async {
      final lock = MlProcessLock.instance;
      var resetRan = false;
      var metadataSyncRan = false;
      MlLockAttempt? deniedAttempt;

      final resetAttempt = await lock.tryRunExclusive(
        MlOperation.clearData,
        () async {
          resetRan = true;
          deniedAttempt = await lock.tryRunExclusive(
            MlOperation.metadataSync,
            () async => metadataSyncRan = true,
            background: false,
          );
        },
        background: false,
      );

      expect(resetAttempt, MlLockAttempt.ran);
      expect(resetRan, isTrue);
      expect(deniedAttempt, MlLockAttempt.deniedFunnelBusy);
      expect(metadataSyncRan, isFalse);
      expect(calls, ["acquire:clearData", "release"]);

      final retryAttempt = await lock.tryRunExclusive(
        MlOperation.metadataSync,
        () async => metadataSyncRan = true,
        background: false,
      );

      expect(retryAttempt, MlLockAttempt.ran);
      expect(metadataSyncRan, isTrue);
      expect(calls, [
        "acquire:clearData",
        "release",
        "acquire:metadataSync",
        "release",
      ]);
    },
  );

  test(
    "a nested non-waiting metadata sync returns without deadlocking",
    () async {
      MlLockAttempt? nestedAttempt;
      final outerAttempt = await MlProcessLock.instance.tryRunExclusive(
        MlOperation.fullRun,
        () async {
          nestedAttempt = await MlProcessLock.instance
              .tryRunExclusive(
                MlOperation.metadataSync,
                () async {},
                background: false,
              )
              .timeout(const Duration(seconds: 1));
        },
        background: false,
      );

      expect(outerAttempt, MlLockAttempt.ran);
      expect(nestedAttempt, MlLockAttempt.deniedFunnelBusy);
      expect(calls, ["acquire:fullRun", "release"]);
    },
  );
}
