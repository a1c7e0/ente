import "package:ente_ui/components/loading_widget.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/ui/settings/ml/machine_learning_settings_page.dart";

void main() {
  testWidgets("body detector and embedder have named progress rows", (
    tester,
  ) async {
    for (final (model, title) in [
      ("body-detection", "Body Detection Model"),
      ("body-embedding", "Body Embedding Model"),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: lightThemeData,
          home: Scaffold(
            body: ModelDownloadProgressRow(
              model: model,
              downloaded: 25,
              total: 100,
            ),
          ),
        ),
      );
      expect(find.text(title), findsOneWidget);
      expect(find.text("25%"), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets("unknown length shows activity without division by zero", (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: lightThemeData,
        home: const Scaffold(
          body: ModelDownloadProgressRow(
            model: "body-detection",
            downloaded: 25,
            total: 0,
          ),
        ),
      ),
    );
    expect(find.byType(EnteLoadingWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
