import "dart:convert";

import "package:flutter/foundation.dart";
import "package:photos/db/common/base.dart";
import "package:photos/models/ml/body_feedback.dart";
import "package:sqlite_async/sqlite_async.dart";
import "package:uuid/uuid.dart";

class PendingBodyFeedback {
  PendingBodyFeedback(this.ownerID, this.fileID, this.revision, this.patch);
  final int ownerID;
  final int fileID;
  final String revision;
  final BodyFeedbackPatch patch;
}

/// Independent of the Dart/Rust ML database backend. One small patch per photo
/// is authoritative until the existing encrypted metadata writer acknowledges it.
class BodyFeedbackDB with SqlDbBase {
  BodyFeedbackDB._();
  static final instance = BodyFeedbackDB._();
  SqliteDatabase? _testDatabase;
  @visibleForTesting
  BodyFeedbackDB.forTesting(SqliteDatabase database) : _testDatabase = database;

  Future<SqliteDatabase> get database => _testDatabase != null
      ? Future.value(_testDatabase!)
      : getOrOpenDatabase(
          () => openMigratedDatabase("ente.ml.feedback.db", schema),
        );

  static const schema = [
    """
    CREATE TABLE pending_body_feedback (
      owner_id INTEGER NOT NULL, file_id INTEGER NOT NULL,
      revision TEXT NOT NULL, patch TEXT NOT NULL,
      PRIMARY KEY(owner_id, file_id)
    );
  """,
  ];

  Future<void> enqueue(
    int ownerID,
    Map<int, BodyFeedbackPatch> patches, {
    bool Function()? isCurrentSession,
  }) async {
    final db = await database;
    await db.writeTransaction((tx) async {
      for (final entry in patches.entries) {
        if (isCurrentSession != null && !isCurrentSession()) {
          throw StateError(
            "Feedback account session changed before local commit",
          );
        }
        final old = await tx.getOptional(
          "SELECT patch FROM pending_body_feedback WHERE owner_id = ? AND file_id = ?",
          [ownerID, entry.key],
        );
        final patch = old == null
            ? entry.value
            : BodyFeedbackPatch.fromJson(
                jsonDecode(old["patch"] as String) as Map<String, dynamic>,
              ).merge(entry.value);
        await tx.execute(
          "INSERT OR REPLACE INTO pending_body_feedback(owner_id,file_id,revision,patch) VALUES (?,?,?,?)",
          [ownerID, entry.key, const Uuid().v4(), jsonEncode(patch.toJson())],
        );
      }
      if (isCurrentSession != null && !isCurrentSession()) {
        throw StateError(
          "Feedback account session changed before local commit",
        );
      }
    });
  }

  Future<List<PendingBodyFeedback>> pending(int ownerID) async {
    final rows = await (await database).getAll(
      "SELECT * FROM pending_body_feedback WHERE owner_id = ? ORDER BY file_id",
      [ownerID],
    );
    return rows
        .map(
          (row) => PendingBodyFeedback(
            ownerID,
            row["file_id"] as int,
            row["revision"] as String,
            BodyFeedbackPatch.fromJson(
              jsonDecode(row["patch"] as String) as Map<String, dynamic>,
            ),
          ),
        )
        .toList();
  }

  Future<void> acknowledge(PendingBodyFeedback item) async {
    await (await database).execute(
      "DELETE FROM pending_body_feedback WHERE owner_id = ? AND file_id = ? AND revision = ?",
      [item.ownerID, item.fileID, item.revision],
    );
  }

  Future<void> discardFiles(int ownerID, Iterable<int> fileIDs) async {
    final db = await database;
    await db.writeTransaction((tx) async {
      for (final id in fileIDs) {
        await tx.execute(
          "DELETE FROM pending_body_feedback WHERE owner_id = ? AND file_id = ?",
          [ownerID, id],
        );
      }
    });
  }

  Future<void> discardPerson(
    int ownerID,
    String personID,
    Iterable<int> fileIDs,
  ) async {
    final db = await database;
    await db.writeTransaction((tx) async {
      for (final id in fileIDs) {
        final row = await tx.getOptional(
          "SELECT patch FROM pending_body_feedback WHERE owner_id = ? AND file_id = ?",
          [ownerID, id],
        );
        if (row == null) continue;
        final patch = BodyFeedbackPatch.fromJson(
          jsonDecode(row["patch"] as String) as Map<String, dynamic>,
        );
        patch.manual.remove(personID);
        for (final key in patch.bodies.keys.toList()) {
          final body = patch.bodies[key] as Map;
          (body["decisions"] as Map).remove(personID);
          if ((body["decisions"] as Map).isEmpty &&
              body.keys.every(
                (key) =>
                    key == "decisions" ||
                    key == "expectedGroup" ||
                    key == "expectedGroups",
              )) {
            patch.bodies.remove(key);
          }
        }
        if (patch.bodies.isEmpty && patch.manual.isEmpty) {
          await tx.execute(
            "DELETE FROM pending_body_feedback WHERE owner_id = ? AND file_id = ?",
            [ownerID, id],
          );
        } else {
          await tx.execute(
            "UPDATE pending_body_feedback SET revision = ?, patch = ? WHERE owner_id = ? AND file_id = ?",
            [const Uuid().v4(), jsonEncode(patch.toJson()), ownerID, id],
          );
        }
      }
    });
  }

  Future<void> clear() async =>
      (await database).execute("DELETE FROM pending_body_feedback");
}
