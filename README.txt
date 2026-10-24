Widget-harness captures for fix/review-suggestion-refresh-upstream.
These use synthetic thumbnail bytes and loaded app fonts.
Before/after refers to before deletion and after handling the deletion event, not a physical-device recording.
Reproduce in mobile/apps/photos with:
flutter test --no-pub --dart-define=reviewScreenshotDir=/tmp/review-refresh test/ui/viewer/people/review_suggestion_refresh_test.dart
