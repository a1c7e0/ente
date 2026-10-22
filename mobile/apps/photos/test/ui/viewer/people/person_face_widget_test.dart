import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/ui/viewer/people/person_face_widget.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("generic people changes reload person and cluster avatars", (
    tester,
  ) async {
    await _expectGenericEventReloads(tester, personId: "person-1");
    await _expectGenericEventReloads(tester, clusterID: "cluster-1");
  });

  testWidgets("scoped people changes reload only the matching person", (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: PersonFaceWidget(personId: "person-1")),
    );
    await tester.pump();
    final dynamic state = tester.state(find.byType(PersonFaceWidget));
    final initialLoad = state.faceCropFuture;

    Bus.instance.fire(PeopleChangedEvent(person: _person("person-2")));
    await tester.pump();
    expect(identical(state.faceCropFuture, initialLoad), isTrue);

    Bus.instance.fire(PeopleChangedEvent(person: _person("person-1")));
    await tester.pump();
    expect(identical(state.faceCropFuture, initialLoad), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _expectGenericEventReloads(
  WidgetTester tester, {
  String? personId,
  String? clusterID,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PersonFaceWidget(personId: personId, clusterID: clusterID),
    ),
  );
  await tester.pump();
  final dynamic state = tester.state(find.byType(PersonFaceWidget));
  final initialLoad = state.faceCropFuture;

  Bus.instance.fire(PeopleChangedEvent());
  await tester.pump();

  expect(identical(state.faceCropFuture, initialLoad), isFalse);
  await tester.pumpWidget(const SizedBox.shrink());
}

PersonEntity _person(String id) => PersonEntity(id, PersonData(name: id));
