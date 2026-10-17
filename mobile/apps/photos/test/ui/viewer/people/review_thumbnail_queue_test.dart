import "dart:async";

import "package:flutter_test/flutter_test.dart";
import "package:photos/ui/viewer/people/review_thumbnail_queue.dart";

void main() {
  test(
    "ready face bypasses a pending body, which remains reviewable",
    () async {
      final body = Completer<String>();
      final face = Completer<String>();
      final queue = ReviewThumbnailQueue<String, String>(
        (key) => key == "body" ? body.future : face.future,
      );
      final first = queue.next(["body", "face"]);
      face.complete("face pixels");
      expect(await first, (key: "face", value: "face pixels"));
      final second = queue.next(["body"]);
      body.complete("body pixels");
      expect(await second, (key: "body", value: "body pixels"));
      queue.dispose();
    },
  );

  test("ready body bypasses a pending face", () async {
    final face = Completer<String>();
    final queue = ReviewThumbnailQueue<String, String>(
      (key) => key == "face" ? face.future : Future.value("body pixels"),
    );
    expect(await queue.next(["face", "body"]), (
      key: "body",
      value: "body pixels",
    ));
    queue.dispose();
    face.complete("late pixels");
  });

  test(
    "a full warm window respects candidate order and never reloads it",
    () async {
      final loaded = <int>[];
      final queue = ReviewThumbnailQueue<int, int>((key) async {
        loaded.add(key);
        return key;
      }, capacity: 3);
      queue.prefetch([1, 2, 3, 4, 5]);
      await Future<void>.delayed(Duration.zero);
      expect(loaded, [1, 2, 3]);
      expect(await queue.next([3, 1, 2, 4, 5]), (key: 3, value: 3));
      expect(loaded, [1, 2, 3]);
      queue.prefetch([1, 2, 4, 5]);
      await Future<void>.delayed(Duration.zero);
      expect(loaded, [1, 2, 3, 4]);
      queue.dispose();
    },
  );

  test("prefetch and foreground requests share pending work", () async {
    final pending = Completer<int>();
    var loads = 0;
    final queue = ReviewThumbnailQueue<int, int>((_) {
      loads++;
      return pending.future;
    });
    queue.prefetch([1]);
    queue.prefetch([1]);
    final next = queue.next([1]);
    expect(loads, 1);
    pending.complete(10);
    expect(await next, (key: 1, value: 10));
    queue.dispose();
  });

  test(
    "failed crops never become ready and can be explicitly retried",
    () async {
      var failed = true;
      final queue = ReviewThumbnailQueue<int, int>((key) async {
        if (key == 1 && failed) throw StateError("missing image");
        return key;
      });
      expect(await queue.next([1, 2]), (key: 2, value: 2));
      await expectLater(queue.next([1]), throwsStateError);
      failed = false;
      queue.retryFailures();
      expect(await queue.next([1]), (key: 1, value: 1));
      queue.dispose();
    },
  );

  test(
    "a failed window does not scan or download the entire candidate list",
    () async {
      final loaded = <int>[];
      final queue = ReviewThumbnailQueue<int, int>((key) async {
        loaded.add(key);
        throw StateError("offline");
      });
      await expectLater(
        queue.next(List.generate(100, (i) => i)),
        throwsStateError,
      );
      expect(loaded, [0, 1]);
      queue.dispose();
    },
  );

  test(
    "replacing candidates ignores old pixels without exceeding the limit",
    () async {
      final requests = <int, Completer<int>>{};
      final queue = ReviewThumbnailQueue<int, int>((key) {
        final pending = Completer<int>();
        requests[key] = pending;
        return pending.future;
      }, capacity: 1);
      queue.prefetch([1]);
      final next = queue.next([2]);
      expect(requests.keys, [1]);
      requests[1]!.complete(1);
      await Future<void>.delayed(Duration.zero);
      expect(requests.keys, [1, 2]);
      requests[2]!.complete(2);
      expect(await next, (key: 2, value: 2));
      queue.dispose();
    },
  );

  test(
    "independent review keeps an eight-image budget across whole groups",
    () async {
      final pending = <int, Completer<int>>{};
      final queue = ReviewThumbnailQueue<int, int>(
        (key) {
          final task = Completer<int>();
          pending[key] = task;
          return task.future;
        },
        capacity: 5,
        maxWeight: 8,
        weight: (key) => key == 3 ? 2 : 6,
      );
      final first = queue.next([1, 2, 3, 4]);
      expect(pending.keys, [1, 3]);
      pending[3]!.complete(3);
      expect(await first, (key: 3, value: 3));
      queue.prefetch([1, 2, 4]);
      expect(pending.keys, [1, 3]);
      pending[1]!.complete(1);
      expect(await queue.next([1, 2, 4]), (key: 1, value: 1));
      queue.prefetch([2, 4]);
      expect(pending.keys, [1, 3, 2]);
      queue.dispose();
      pending[2]!.complete(2);
    },
  );

  test(
    "disposal releases the waiting screen and ignores late failures",
    () async {
      final pending = Completer<int>();
      final queue = ReviewThumbnailQueue<int, int>((_) => pending.future);
      final next = queue.next([1]);
      queue.dispose();
      expect(await next, isNull);
      pending.completeError(StateError("late failure"));
      await Future<void>.delayed(Duration.zero);
    },
  );
  test(
    "undo can pin a previous review instead of selecting another ready group",
    () async {
      final queue = ReviewThumbnailQueue<int, int>((key) async => key);
      queue.prefetch([1, 2]);
      await Future<void>.delayed(Duration.zero);
      expect(await queue.next([2]), (key: 2, value: 2));
      queue.dispose();
    },
  );
  test(
    "a failed large group releases the image budget for another group",
    () async {
      final pending = <int, Completer<int>>{};
      final queue = ReviewThumbnailQueue<int, int>(
        (key) {
          final task = Completer<int>();
          pending[key] = task;
          return task.future;
        },
        capacity: 5,
        maxWeight: 8,
        weight: (_) => 6,
      );
      final next = queue.next([1, 2]);
      expect(pending.keys, [1]);
      pending[1]!.completeError(StateError("bad thumbnail"));
      await Future<void>.delayed(Duration.zero);
      expect(pending.keys, [1, 2]);
      pending[2]!.complete(2);
      expect(await next, (key: 2, value: 2));
      queue.dispose();
    },
  );
}
