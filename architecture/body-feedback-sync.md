# Body review feedback synchronization

## Saving feedback

Face acceptance normally writes the local cluster/person mapping; the existing
person reconciliation later updates its encrypted entity. Clearing earlier face
rejections can additionally require an immediate entity update. Body feedback
updates each affected photo's encrypted mldata through the existing bounded,
conflict-checked write path.

Body confirmations, rejections, undo and grouping edits now commit a small local
patch before returning to review. The new `ente.ml.feedback.db` uses the existing
SQLite migration and transaction infrastructure, with one account-scoped record
per photo. It contains decision/group changes and manual assignment deltas, never
embeddings or copied photo metadata. It works with both ML database backends.

The existing file-data sync drains pending feedback under the cross-engine ML
lock. A newly queued edit also attempts an immediate background drain. Uploads are processed in batches of
at most 200 photos, with at most four independent file writes in parallel.
It reuses encrypted mldata conflict retries; person assignment updates merge a
single file delta against the latest entity version. Failed records remain for a
later ordinary sync or restart. An unrelated remote regrouping is not overwritten;
that record stays pending and logs the conflict for inspection or explicit reset.

Pending patches overlay downloaded body indexes and manual assignment reads, so
remote hydration cannot erase unuploaded feedback. A unique revision prevents an
older acknowledgement from deleting a newer undo/edit, even after row replacement.
Successful sync stores the confirmed index before retiring the pending revision.
Existing metadata shapes and server APIs are retained, including manual person
photo assignments for clients without body recognition.

Selected-photo resets discard only successful reset records. Person reset removes
only that person's pending changes; both reset paths serialize with uploads via
the ML process lock. Logout clears the queue; local commits and asynchronous
network writes check their account session. Local-gallery mode is unchanged.

Review actions return after the local durable commit; remote synchronization runs
in the background. Face feedback and review preview behavior are unchanged.

## Validation

Run the focused Flutter tests in `mobile/apps/photos`:

- `test/services/machine_learning/body_feedback_service_test.dart`
- `test/services/machine_learning/ml_photo_reset_service_test.dart`
- `test/models/ml/face/person_cache_test.dart`

Tests cover recovery after reopening the queue, partial failures, account isolation,
revision acknowledgements and undo racing an upload. Real network timing and
phone behavior still require device validation.
