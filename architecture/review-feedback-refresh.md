# Review feedback and preview refresh

Review and cache changes live on `fix/review-feedback-refresh` and are combined
with the other Photos features on `feat/integration-test`. The review invalidation
fixes from [upstream PR #14053](https://github.com/ente/ente/pull/14053) are applied
without replacing the fork's body previews or asynchronous thumbnail queue. Body
feedback persistence has also been promoted separately to `main`; see
[body feedback synchronization](body-feedback-sync.md).

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

Both mobile review surfaces still prepare and display the next candidate while
the current operation completes. For body feedback, completion now means local
durable commit rather than remote acknowledgement. Local failures restore the
reviewed candidate; late thumbnail results cannot override it. No UI counters or
automatic historical rescans are added.

## Deleted and edited candidates

Following the scenario in [upstream #9341](https://github.com/ente/ente/issues/9341),
review surfaces listen for relevant file deletions/hiding and mixed-grouping edits.
They query fresh suggestions and discard their prepared preview window together.
Changes while the cluster preview is open are coalesced until return; changes
during feedback saving are handled after completion. Canceling a naming form also
applies deferred changes. Changes received before a query returns invalidate that
query, including when an older list was previously displayed. Upload IDs match deleted
photos across different local album rows. Moving out of an album is not treated
as deleting the photo from the library.

## Reviews completed on another page

Both review surfaces publish the existing `reviewedSuggestion` event after a
successful feedback write. The all-people card reloads for any reviewed person;
person-specific cards and review pages reload only for their own person. The
sender ignores its own event so its prepared next candidate remains usable.
The notification follows the write even if the user has already navigated back.
Generation checks keep older queries from restoring a completed suggestion.

Widget regressions navigate from the all-people card to either review surface,
accept or reject the last suggestion, and return before or after saving completes.
They also exercise an obsolete query completing after a more recent refresh.

## Crop queue provenance

The crop request queue and its focused tests are adapted from
[upstream #12955](https://github.com/ente/ente/pull/12955), head
`96b9d64394409b2133e0a639f9d3ac3f5f40a8c8`.
It retains the existing TaskQueue concurrency, timeout and cancellation behavior,
while sharing results across callers. Body-specific task suffixes and separate
full-resolution/thumbnail caches remain in place. No upstream benchmark results
are claimed as measurements of this fork.

## Validation

Run `flutter analyze --no-pub` in `mobile/apps/photos`, plus focused Flutter tests:

- `test/services/machine_learning/body_feedback_service_test.dart`
- `test/services/machine_learning/ml_photo_reset_service_test.dart`
- `test/models/ml/face/person_cache_test.dart`
- `test/ui/viewer/people/review_feedback_flow_test.dart`
- `test/ui/viewer/people/review_suggestion_changes_test.dart`
- `test/ui/viewer/people/review_suggestion_refresh_test.dart`
- `test/utils/face/face_crop_request_queue_test.dart`
- Existing review queue, geometry, avatar, and body crop cache regressions.

SQLite tests exercise reopen recovery, account isolation, partial failures,
revision acknowledgement and undo racing a pending upload. Widget tests control
feedback and decoding completion order. Native decoder,
real network timing, and phone behavior still require device validation.
