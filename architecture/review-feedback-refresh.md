# Review feedback and preview refresh

Changes live on `fix/review-feedback-refresh`, based on the existing client cache fixes.

## Saving feedback

Face acceptance normally writes the local cluster/person mapping; the existing
person reconciliation later updates its encrypted entity. Clearing earlier face
rejections can additionally require an immediate entity update. Body feedback
updates each affected photo's encrypted mldata through the existing bounded,
conflict-checked write path.

Both mobile review surfaces now prepare and display the next candidate while
saving. Further feedback and preview navigation remain disabled until the save
succeeds. Failure restores the reviewed candidate and its thumbnails. A late
thumbnail result cannot overwrite that restoration. If an external deletion or
membership edit invalidated the candidate meanwhile, the surface reloads instead
of restoring stale data. This is concurrent UI preparation, not an offline upload
outbox: it does not acknowledge unsaved remote feedback or change server APIs.

## Deleted and edited candidates

Following the scenario in [upstream #9341](https://github.com/ente/ente/issues/9341),
review surfaces listen for relevant file deletions/hiding and mixed-grouping edits.
They query fresh suggestions and discard their prepared preview window together.
Changes while the cluster preview is open are coalesced until return; changes
during feedback saving are handled after completion. Upload IDs match deleted
photos across different local album rows. Moving out of an album is not treated
as deleting the photo from the library.

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

- `test/ui/viewer/people/review_feedback_flow_test.dart`
- `test/ui/viewer/people/review_suggestion_changes_test.dart`
- `test/utils/face/face_crop_request_queue_test.dart`
- Existing review queue, geometry, avatar, and body crop cache regressions.

Widget tests control feedback and decoding completion order. Native decoder,
real network timing, and phone behavior still require device validation.
