import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/face_ml/face_clustering/face_clustering_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/ui/components/toggle_switch_widget.dart";
import "package:photos/ui/settings/ml/ml_clustering_thresholds.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final dio = Dio();
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
  setUp(() async {
    await localSettings.setAutoMergeThresholdOverride(0.24);
    await localSettings.setDefaultClusteringDistanceOverride(0.24);
  });
  tearDown(() {
    PersonService.autoMergeThreshold = PersonService.kDefaultAutoMergeThreshold;
    FaceClusteringService.defaultDistanceThreshold =
        FaceClusteringService.kRecommendedDistanceThreshold;
  });

  Future<void> mount(WidgetTester tester, {bool visible = true}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: lightThemeData,
          home: Scaffold(body: MLClusteringThresholds(visible: visible)),
        ),
      );

  testWidgets(
    "both controls retain runtime and persistence behavior when reopened",
    (tester) async {
      await mount(tester);
      for (var i = 0; i < 2; i++) {
        final slider = find.byType(Slider).at(i);
        final toggle = find.byType(ToggleSwitchWidget).at(i);
        final savedValue = i == 0 ? 0.31 : 0.27;
        final temporaryValue = i == 0 ? 0.29 : 0.25;
        double current() => i == 0
            ? PersonService.autoMergeThreshold
            : FaceClusteringService.defaultDistanceThreshold;
        double? saved() => i == 0
            ? localSettings.autoMergeThresholdOverride
            : localSettings.defaultClusteringDistanceOverride;
        tester.widget<Slider>(slider).onChanged!(savedValue);
        await tester.pump();
        expect(current(), closeTo(savedValue, 0.00001));
        expect(saved(), closeTo(savedValue, 0.00001));
        await tester.widget<ToggleSwitchWidget>(toggle).onChanged();
        await tester.pump();
        tester.widget<Slider>(slider).onChanged!(temporaryValue);
        await tester.pump();
        expect(current(), closeTo(temporaryValue, 0.00001));
        expect(saved(), closeTo(savedValue, 0.00001));
        await tester.widget<ToggleSwitchWidget>(toggle).onChanged();
        await tester.pump();
        expect(saved(), closeTo(temporaryValue, 0.00001));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester);
      expect(
        tester.widgetList<Slider>(find.byType(Slider)).map((w) => w.value),
        [closeTo(0.29, 0.00001), closeTo(0.25, 0.00001)],
      );
      expect(find.text("Auto-merge threshold"), findsOneWidget);
      expect(find.text("Default clustering distance"), findsOneWidget);
    },
  );

  testWidgets("disabled ML keeps initialization and clamps saved thresholds", (
    tester,
  ) async {
    await localSettings.setAutoMergeThresholdOverride(0.5);
    await localSettings.setDefaultClusteringDistanceOverride(-1);
    await mount(tester, visible: false);
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
    expect(PersonService.autoMergeThreshold, 0.35);
    expect(FaceClusteringService.defaultDistanceThreshold, 0.10);
    expect(localSettings.autoMergeThresholdOverride, 0.35);
    expect(localSettings.defaultClusteringDistanceOverride, 0.10);
    await mount(tester);
    expect(tester.widgetList<Slider>(find.byType(Slider)).map((w) => w.value), [
      0.35,
      0.10,
    ]);
  });
}
