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
import "package:photos/events/people_changed_event.dart";
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
    for (final accepted in [false, true]) {
      for (final leaveBeforeSave in [false, true]) {
        testWidgets(
          "all-people card drops the last review completed on ${standalone ? 'review' : 'person'} page ($accepted, return before save: $leaveBeforeSave)",
          (tester) async {
            final harness = await _mount(
              tester,
              false,
              allPeople: true,
              singleSuggestion: true,
            );
            final navigator = Navigator.of(
              tester.element(find.byType(PersonGallerySuggestion)),
            );
            unawaited(
              navigator.push(
                MaterialPageRoute<void>(
                  builder: (_) => standalone
                      ? harness.createPersonReview(true)
                      : Scaffold(body: harness.createPersonReview(false)),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text(accepted ? "Yes" : "No"));
            await _advanceTransition(tester);
            // The successful write has removed the last candidate from storage.
            harness.suggestions = [];
            if (leaveBeforeSave) {
              navigator.pop();
              await tester.pumpAndSettle();
            }
            harness.save.complete();
            await tester.pumpAndSettle();
            if (!leaveBeforeSave) {
              navigator.pop();
              await tester.pumpAndSettle();
            }
            expect(harness.state.allSuggestions, isEmpty);
            expect(find.byType(ReviewThumbnailWidget), findsNothing);
            expect(harness.disposedLoaders, greaterThanOrEqualTo(1));
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }

  testWidgets("all-people card ignores an obsolete query after review", (
    tester,
  ) async {
    final harness = await _mount(tester, false, allPeople: true);
    final oldSuggestions = List<ClusterSuggestion>.of(harness.suggestions);
    final stale = Completer<List<ClusterSuggestion>>();
    harness.loadOverride = () => stale.future;
    void reviewed() => Bus.instance.fire(
      PeopleChangedEvent(
        type: PeopleEventType.reviewedSuggestion,
        person: oldSuggestions.first.person,
      ),
    );
    reviewed();
    await tester.pump();
    harness.loadOverride = null;
    harness.suggestions = [];
    reviewed();
    await tester.pumpAndSettle();
    stale.complete(oldSuggestions);
    await tester.pumpAndSettle();
    expect(harness.state.allSuggestions, isEmpty);
    expect(find.byType(ReviewThumbnailWidget), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final standalone in [false, true]) {
    final surface = standalone ? "independent review" : "person card";

    testWidgets("$surface refreshes only for its reviewed person", (
      tester,
    ) async {
      final harness = await _mount(tester, standalone);
      Bus.instance.fire(
        PeopleChangedEvent(
          type: PeopleEventType.reviewedSuggestion,
          person: PersonEntity("other", PersonData(name: "Other")),
        ),
      );
      await tester.pumpAndSettle();
      expect(harness.loads, 1);
      final reviewedPerson = harness.suggestions.first.person;
      harness.suggestions = [];
      Bus.instance.fire(
        PeopleChangedEvent(
          type: PeopleEventType.reviewedSuggestion,
          person: reviewedPerson,
        ),
      );
      await tester.pumpAndSettle();
      expect(harness.loads, 2);
      expect(harness.state.allSuggestions, isEmpty);
      expect(find.byType(ReviewThumbnailWidget), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      "$surface prepares next group during save and prevents a second write",
      (tester) async {
        final harness = await _mount(tester, standalone);
        await tester.tap(find.text("Yes"));
        await _advanceTransition(tester);
        expect(harness.state.currentSuggestionIndex, 1);
        expect(harness.savedClusters, ["first"]);
        await tester.tap(find.text("No"));
        await tester.pump();
        expect(harness.savedClusters, ["first"]);
        harness.save.complete();
        await tester.pumpAndSettle();
        expect(harness.canGiveFeedback, isTrue);
        expect(
          harness.loads,
          1,
          reason: "keep the sender's prepared next group",
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets("$surface restores reviewed group when its save fails", (
      tester,
    ) async {
      final harness = await _mount(tester, standalone);
      await tester.tap(find.text("Yes"));
      await _advanceTransition(tester);
      expect(harness.state.currentSuggestionIndex, 1);
      harness.save.completeError(StateError("save failed"));
      await _advanceTransition(tester);
      expect(harness.state.currentSuggestionIndex, 0);
      expect(harness.state.allSuggestions.first.clusterIDToMerge, "first");
      expect(harness.canGiveFeedback, isTrue);
      if (standalone) expect(harness.state.pastUserFeedback, isEmpty);
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
      expect(harness.state.currentSuggestionIndex, 0);
      harness.nextThumbnails!.complete();
      await _advanceTransition(tester);
      expect(harness.state.currentSuggestionIndex, 0);
      expect(harness.canGiveFeedback, isTrue);
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
      expect(harness.state.allSuggestions, isEmpty);
      expect(find.byType(ReviewThumbnailWidget), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    });

    testWidgets("$surface discards deleted candidate and prepared thumbnails", (
      tester,
    ) async {
      final harness = await _mount(tester, standalone);
      harness.suggestions = [];
      Bus.instance.fire(
        FilesUpdatedEvent([
          EnteFile()
            ..uploadedFileID = 1
            ..generatedID = 999,
        ], type: EventType.deletedFromEverywhere),
      );
      await tester.pumpAndSettle();
      expect(harness.loads, 2);
      expect(harness.disposedLoaders, 1);
      expect(harness.state.allSuggestions, isEmpty);
      expect(find.byType(ReviewThumbnailWidget), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Future<void> _advanceTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

class _Harness {
  _Harness(this.standalone);
  final bool standalone;
  final save = Completer<void>();
  final savedClusters = <String>[];
  Completer<void>? nextThumbnails;
  List<ClusterSuggestion> suggestions = [];
  Future<List<ClusterSuggestion>> Function()? loadOverride;
  late Widget Function(bool standalone) createPersonReview;
  int loads = 0;
  int disposedLoaders = 0;
  late dynamic state;
  bool get canGiveFeedback => standalone
      ? state.canGiveFeedback as bool
      : !(state.isProcessing as bool);
}

Future<_Harness> _mount(
  WidgetTester tester,
  bool standalone, {
  bool allPeople = false,
  bool singleSuggestion = false,
}) async {
  final thumbnail = await tester.runAsync(
    () => ReviewThumbnail.prepare(
      base64Decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQI12P4z8DwHwAFAAH/cpxSZwAAAABJRU5ErkJggg==",
      ),
    ),
  );
  final harness = _Harness(standalone);
  final person = PersonEntity("person", PersonData(name: "Alex"));
  ClusterSuggestion suggestion(String cluster, int id) =>
      ClusterSuggestion(person, cluster, 0.1, false, [
        EnteFile()
          ..uploadedFileID = id
          ..creationTime = id,
      ], []);
  harness.suggestions = [
    suggestion("first", 1),
    if (!singleSuggestion) suggestion("second", 2),
  ];
  Future<List<ClusterSuggestion>> load() async {
    harness.loads++;
    return harness.loadOverride?.call() ?? List.of(harness.suggestions);
  }

  Future<void> save(ClusterSuggestion suggestion, bool accepted) {
    harness.savedClusters.add(suggestion.clusterIDToMerge);
    return harness.save.future;
  }

  ReviewThumbnailLoader loader(int count) => _Loader(
    count,
    thumbnail!,
    () => harness.disposedLoaders++,
    (suggestion) => suggestion.clusterIDToMerge == "second"
        ? harness.nextThumbnails?.future ?? Future<void>.value()
        : Future<void>.value(),
  );
  harness.createPersonReview = (standalone) => standalone
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
  final Widget review = standalone
      ? PersonReviewClusterSuggestion(
          person,
          loadSuggestions: load,
          saveFeedback: save,
          createThumbnailLoader: loader,
        )
      : PersonGallerySuggestion(
          person: allPeople ? null : person,
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
  harness.state = tester.state(find.byWidget(review));
  return harness;
}

class _Loader extends ReviewThumbnailLoader {
  _Loader(super.count, this.thumbnail, this.onDispose, this.beforeLoad);
  final ReviewThumbnail thumbnail;
  final VoidCallback onDispose;
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
  @override
  void dispose() => onDispose();
}
