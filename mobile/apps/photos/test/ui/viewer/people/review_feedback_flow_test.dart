import "dart:async";
import "dart:convert";

import "package:dio/dio.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/face_ml/feedback/cluster_feedback.dart";
import "package:photos/ui/viewer/people/person_cluster_suggestion.dart";
import "package:photos/ui/viewer/people/person_gallery_suggestion.dart";
import "package:photos/ui/viewer/people/review_thumbnail.dart";
import "package:photos/ui/viewer/people/review_thumbnail_loader.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({"remote_flags": "{}"});
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              data: <String, dynamic>{},
              statusCode: 200,
            ),
          ),
        ),
      );
    ServiceLocator.instance.init(
      await SharedPreferences.getInstance(),
      dio,
      dio,
      dio,
      PackageInfo(
        appName: "Photos",
        packageName: "photos",
        version: "1",
        buildNumber: "1",
      ),
    );
  });

  for (final standalone in [false, true]) {
    final surface = standalone ? "independent review" : "person card";

    testWidgets(
      "$surface prepares next group during save and prevents a second write",
      (tester) async {
        final harness = await _mount(tester, standalone);
        await tester.tap(find.text("Yes"));
        await _advanceTransition(tester);
        expect(harness.visibleClusters(tester), ["second"]);
        expect(harness.savedClusters, ["first"]);
        await tester.tap(find.text("No"));
        await tester.pump();
        expect(harness.savedClusters, ["first"]);
        harness.save.complete();
        await tester.pumpAndSettle();
        expect(
          harness.loads,
          1,
          reason: "keep the sender's prepared next group",
        );
        await harness.expectFeedbackEnabled(tester, "second");
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets("$surface restores reviewed group when its save fails", (
      tester,
    ) async {
      final harness = await _mount(tester, standalone);
      await tester.tap(find.text("Yes"));
      await _advanceTransition(tester);
      expect(harness.visibleClusters(tester), ["second"]);
      harness.save.completeError(StateError("save failed"));
      await _advanceTransition(tester);
      expect(harness.visibleClusters(tester), ["first"]);
      if (standalone) expect(find.byIcon(Icons.undo_outlined), findsNothing);
      await harness.expectFeedbackEnabled(tester, "first");
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    });

    testWidgets("$surface ignores late thumbnails after a failed save", (
      tester,
    ) async {
      final harness = await _mount(tester, standalone);
      harness.nextThumbnails = Completer<void>();
      await tester.tap(find.text("Yes"));
      await _advanceTransition(tester);
      harness.save.completeError(StateError("save failed"));
      await _advanceTransition(tester);
      expect(harness.visibleClusters(tester), ["first"]);
      harness.nextThumbnails!.complete();
      await _advanceTransition(tester);
      expect(harness.visibleClusters(tester), ["first"]);
      await harness.expectFeedbackEnabled(tester, "first");
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    });

    testWidgets("$surface does not restore a deleted group on save failure", (
      tester,
    ) async {
      final harness = await _mount(tester, standalone);
      await tester.tap(find.text("Yes"));
      await _advanceTransition(tester);
      harness.suggestions = [];
      Bus.instance.fire(
        FilesUpdatedEvent([
          EnteFile()..uploadedFileID = 2,
        ], type: EventType.deletedFromEverywhere),
      );
      await tester.pump();
      expect(
        harness.loads,
        1,
        reason: "defer reload until the active save finishes",
      );
      harness.save.completeError(StateError("save failed"));
      await _advanceTransition(tester);
      expect(harness.loads, 2);
      expect(harness.visibleClusters(tester), isEmpty);
      expect(find.byType(ReviewThumbnailWidget), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    });
  }
}

Future<void> _advanceTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

class _Harness {
  Completer<void> save = Completer<void>();
  final savedClusters = <String>[];
  Completer<void>? nextThumbnails;
  List<ClusterSuggestion> suggestions = [];
  int loads = 0;
  List<String> visibleClusters(WidgetTester tester) => tester
      .widgetList<ReviewThumbnailWidget>(find.byType(ReviewThumbnailWidget))
      .map(
        (widget) => switch (widget.key) {
          ValueKey<(String, String, int?)>(:final value) => value.$2,
          ValueKey<(String, int?)>(:final value) => value.$1,
          _ => throw StateError("Missing review thumbnail identity"),
        },
      )
      .toSet()
      .toList();

  Future<void> expectFeedbackEnabled(
    WidgetTester tester,
    String cluster,
  ) async {
    final dismiss = find.text("OK");
    if (dismiss.evaluate().isNotEmpty) {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    final previous = List<String>.of(savedClusters);
    save = Completer<void>();
    await tester.tap(find.text("No"));
    await tester.pump();
    expect(savedClusters, [...previous, cluster]);
    save.complete();
    await tester.pumpAndSettle();
  }
}

Future<_Harness> _mount(WidgetTester tester, bool standalone) async {
  final thumbnail = await tester.runAsync(
    () => ReviewThumbnail.prepare(
      base64Decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQI12P4z8DwHwAFAAH/cpxSZwAAAABJRU5ErkJggg==",
      ),
    ),
  );
  final harness = _Harness();
  final person = PersonEntity("person", PersonData(name: "Alex"));
  ClusterSuggestion suggestion(String cluster, int id) =>
      ClusterSuggestion(person, cluster, 0.1, false, [
        EnteFile()
          ..uploadedFileID = id
          ..creationTime = id,
      ], []);
  harness.suggestions = [suggestion("first", 1), suggestion("second", 2)];
  Future<List<ClusterSuggestion>> load() async {
    harness.loads++;
    return List.of(harness.suggestions);
  }

  Future<void> save(ClusterSuggestion suggestion, bool accepted) {
    harness.savedClusters.add(suggestion.clusterIDToMerge);
    return harness.save.future;
  }

  ReviewThumbnailLoader loader(int count) => _Loader(
    count,
    thumbnail!,
    (suggestion) => suggestion.clusterIDToMerge == "second"
        ? harness.nextThumbnails?.future ?? Future<void>.value()
        : Future<void>.value(),
  );
  final Widget review = standalone
      ? PersonReviewClusterSuggestion(
          person,
          loadSuggestions: load,
          saveFeedback: save,
          createThumbnailLoader: loader,
        )
      : PersonGallerySuggestion(
          person: person,
          loadSuggestions: load,
          saveFeedback: save,
          createThumbnailLoader: loader,
        );
  await tester.pumpWidget(
    MaterialApp(
      theme: lightThemeData,
      localizationsDelegates: StringsLocalizations.localizationsDelegates,
      supportedLocales: StringsLocalizations.supportedLocales,
      home: Scaffold(body: review),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

class _Loader extends ReviewThumbnailLoader {
  _Loader(super.count, this.thumbnail, this.beforeLoad);
  final ReviewThumbnail thumbnail;
  final Future<void> Function(ClusterSuggestion) beforeLoad;
  @override
  Future<({ClusterSuggestion suggestion, ReviewThumbnails thumbnails})?> next(
    Iterable<ClusterSuggestion> candidates,
  ) async {
    final suggestion = candidates.firstOrNull;
    if (suggestion == null) return null;
    await beforeLoad(suggestion);
    return (
      suggestion: suggestion,
      thumbnails: {
        for (final file in suggestion.filesInCluster)
          file.uploadedFileID!: thumbnail,
      },
    );
  }

  @override
  void prefetch(Iterable<ClusterSuggestion> candidates) {}
}
