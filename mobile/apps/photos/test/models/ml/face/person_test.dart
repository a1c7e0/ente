import "package:flutter_test/flutter_test.dart";
import "package:photos/models/ml/face/person.dart";

void main() {
  group("PersonData.fromJson", () {
    test("treats a null name as an ignored unnamed person", () {
      final person = PersonData.fromJson({
        "name": null,
        "assigned": [
          {
            "id": "cluster-1",
            "faces": ["face-1"],
          },
        ],
      });

      expect(person.name, isEmpty);
      expect(person.isIgnored, isTrue);
      expect(person.assigned.single.id, "cluster-1");
      expect(person.assigned.single.faces, {"face-1"});
    });

    test("preserves auto-unnamed state and clears it when named", () {
      final person = PersonData.fromJson({
        "name": "",
        "isUnnamed": true,
        "assigned": [],
      });

      expect(person.isIgnored, isFalse);
      final restored = PersonData.fromJson(person.toJson());
      expect(restored.isUnnamed, isTrue);
      expect(restored.isIgnored, isFalse);
      final renamed = restored.copyWith(name: "Jordan");
      expect(renamed.name, "Jordan");
      expect(renamed.isUnnamed, isFalse);
      expect(renamed.isIgnored, isFalse);
    });

    test("keeps missing unnamed marker false for legacy empty names", () {
      final legacy = PersonData.fromJson({"name": ""});

      expect(legacy.isUnnamed, isFalse);
      expect(legacy.isIgnored, isTrue);
    });
  });
}
