# Body recognition in Photos

Body recognition adds evidence for photos without a usable face. It does not
change face or CLIP models, their indexing versions, or face clustering. Mobile
and Desktop share the Rust detector and embedding implementation.

## Models

The human detector uses class 0 of Ente's existing, pinned
`yolov5s_object_fp16.onnx` asset. Body embeddings use the public
`osnet_ain_x1_0_msmt17.onnx` export of the same official MSMT17 checkpoint
used by reid-demo. Both assets go through AssetStore. The embedder is about
8.9 MB; it expects ImageNet-normalized RGB CHW crops of 128×256 pixels and
returns 512-dimensional vectors. Its batch dimension is dynamic; inference
runs at most 16 crops per batch, without padding the final batch. Returned vectors are
L2-normalized. Body sessions run on CPU and are released with the existing ML
runtime.

Model hashes and URLs are part of the catalog. Weights are hosted as a separate
`body-reid-models-v1` release asset in this fork and are not checked into Git.
`rust/tools/body-reid/export.py` pins and verifies the architecture and checkpoint,
exports dynamic-batch ONNX, and checks PyTorch/ONNX parity at batches 1, 3, 16
and 17. Run it with the dependencies specified in its docstring and an explicit
`--output-dir`. The release includes the export manifest. The catalog verifies
the exported file's size and SHA-256 before use. The earlier unshipped x0.25
prototype uses a distinct model identifier; its vectors are not mixed with AIN.
Export preserves checkpoint tensors without host-side constant folding so the
file checksum is reproducible; ONNX Runtime performs graph optimization when
loading the model. Face/CLIP indexing versions stay unchanged.

The fork's `Release (body recognition models)` workflow can reproduce and publish
the resource release. It checks the exact catalog checksum before publication;
rerunning it verifies existing assets instead of replacing them. It is restricted
to this fork, publishes a prerelease, and does not change the latest app release.

## Remote data

Body results are an independent top-level `body` subtype of the existing
gzipped, file-key-encrypted `mldata` JSON. The server stores the same opaque
object as before; no new object type or server SQL column is needed.

```json
{
  "body": {
    "version": 1,
    "model": "osnet-ain-x1.0-msmt17-v1",
    "client": "ente",
    "width": 4000,
    "height": 3000,
    "detections": [
      {
        "bodyID": "body:42_10000_10000_40000_80000",
        "box": { "x": 0.1, "y": 0.1, "width": 0.3, "height": 0.7 },
        "score": 0.9,
        "embedding": [],
        "linkedFaceID": null,
        "decisions": {}
      }
    ]
  }
}
```

The example omits the 512 embedding values. Coordinates refer to the decoded,
EXIF-oriented image and are normalized to [0, 1]. Empty `detections` means a
completed index with no bodies, rather than missing work. Body IDs use a separate
namespace; they are not inserted into face tables, face clusters, or cgroups'
assigned face lists.

Unknown top-level mldata keys are preserved. Body parsing is separate from face
and CLIP parsing. Unknown body versions/vector spaces are retained without being
used or overwritten by the current body indexer. The protocol permits independent
body metadata without face/CLIP subtypes; legacy readers already treat absent
face/CLIP subtypes as not indexed. Existing face and CLIP
values are retained on all body writes.

Mobile now carries the fetched `updatedAt` into writes, as Desktop already did.
Face, CLIP and body indexing use the same metadata mutation/retry path on each
client. A 409 conflict refetches the latest raw JSON and reapplies only the
intended subtype mutation, up to three attempts. Body review also uses this
shared writer; its retry loop is not separate from face/CLIP writes. A body producer adopts an
already compatible result published by another device instead of replacing its
review decisions. The server's current pre-write version check is not an atomic
transaction around object-store and SQL writes, and legacy clients can still
write without it; the extension does not promise stronger distributed write
guarantees than the underlying protocol.

## Local data and scheduling

Mobile appends migration 17 to both Dart and Rust SQLite schemas, adding
`body_index(file_id, data, ml_version)` to the existing ML databases, including
the separate local-gallery database. Its JSON contains the body subtype and
review decisions. Desktop upgrades the existing `ml` IndexedDB to version 2,
adding a `body-index` store. Face/CLIP records are not rebuilt by this migration.

Body completion is recorded independently of face/CLIP completion, but does not
schedule new work. The original face/CLIP/pet eligibility rules and indexing
progress remain unchanged. Body inference accompanies normal image indexing;
already indexed photos are not queued merely because body data is missing.
Hydrating compatible remote face/CLIP indexes also does not trigger body-only
inference. Historical body backfill is not implemented. Existing ML consent,
connectivity, compute control and local indexing settings continue to gate
inference. Body failures retain successful face/CLIP results. Corrupt input skip
markers also cover body work.

A shared ML metadata status-diff cursor refreshes face, CLIP and body data for
files already present in the local ML database. It does not schedule image
inference. Mobile starts the new cursor at the previous file-data sync position
rather than redownloading all historical metadata. Mobile ML metadata sync
failures do not fail the original file-data status sync. Log out and ML database clearing remove
body rows; deleted/missing files are excluded from matching and body rows are
pruned through file-data deletion and existing cleanup paths.

## Matching

Body samples are anchored to face identities through geometric face containment.
Only face-backed samples supply identity evidence. Unknown face clusters compete
in the ambiguity calculation and receive high-confidence body photos in their
existing galleries and photo counts. Their face-based visibility thresholds and
naming/ignore operations are unchanged; the body layer does not create person
entities. Body-derived attachments do not seed face clustering or become new
body anchors.

Mobile local-gallery mode retains body detection, embedding generation and local
index storage. Body identity matching, body additions to unnamed galleries and
body identity tags are limited to account mode, using uploaded file IDs and the
account ML database. The upstream local face-gallery flow is unchanged. No
historical body-only rescan is scheduled.

The initial attachment gates are cosine similarity ≥0.74, best-minus-runner-up
margin ≥0.05, capture-time difference ≤3 hours and one person per photo. Review
candidates start at cosine 0.63. Missing timestamps are not treated as a common
event. Mobile timestamps are microseconds; Desktop photo-local sort timestamps
are milliseconds. These gates are conservative starting settings, not an
accuracy claim or a new calibration result. The detector also applies score,
NMS and minimum relative height filters; this version does not add a pose model.

Automatic memberships are derived locally and merged into person photo queries,
counts and the photo information panel. They are not written into
`manuallyAssigned`. A previous positive human decision suppresses automatic
reassignment, including after the old photo tag or person is removed.

Removing an automatic body photo from an unnamed face cluster records the
optional `rejectedAnchorFaceIDs` field on the body detection. It refers to stable
face IDs rather than a device-local cluster ID, so naming or re-clustering does
not silently discard the rejection. Rejected identities remain competitors when
computing the margin; a rejection must not turn a runner-up into an automatic
claim. Clients that do not understand this optional field preserve it with the
rest of the body metadata. Existing account/local-mode edit restrictions remain
in force.

## Differences from reid-demo

The integration retains OSNet-AIN x1.0, geometric face/body association, the
0.74 attachment threshold, 0.05 ambiguity margin, 0.63 review threshold,
three-hour capture-time guard and same-photo identity exclusion. It reuses
Ente's generic person/pet detector rather than adding the demo's separate
person-detector runtime. It does not replace Ente's face model or clustering.

The attachment algorithm is deliberately not identical to the demo. The demo's
`fusion.body_attach` compares a candidate time against the mean of an identity's
seed timestamps within a pass, then immediately appends accepted body vectors
as additional matching evidence. Ente compares each candidate against individual
face-linked body anchors within three hours and never promotes an automatic
body attachment into a new anchor. Missing/nonpositive timestamps are excluded.
Review grouping additionally uses complete-link similarity >=0.8 with pairwise
three-hour bounds, so a similarity chain cannot bridge dissimilar endpoints.
The demo's legacy/fused configuration entries are not all active attachment
rules and were not copied wholesale. Bounded two/three-hop propagation remains
an evaluated proposal, not enabled behavior.

## Storage and review rendering

Mobile stores each photo's body index as JSON TEXT in the existing ML database's
`body_index` table. The JSON contains 512-dimensional vectors as numbers, boxes,
IDs, model/schema versions and review feedback. Desktop stores the corresponding
structured indexes in IndexedDB. Rendered body crops are local cache files, not
new fields or image bytes in mldata. Remote mldata already goes through gzip
before encryption on both clients.

Newly written vectors are rounded to four significant decimal digits and retain
the existing numeric-array shape. A precision marker is informational; older
body clients still read the vectors as ordinary numbers. On 7,877 production
OSNet vectors from Market-1501, the mean absolute pairwise cosine change was
`9.4e-6` (maximum `6.7e-5`). Across 62,047,129 pairs, 62 crossed the 0.74 match
cutoff and 20 crossed the 0.8 review-group cutoff. In a 500-vector, one-body
per-photo serialization sample, median gzipped body metadata fell from 3,728 to
1,390 bytes (63%). These measurements estimate vector-heavy metadata; real
albums vary with detections per photo, feedback and the rest of mldata.
The Penn-Fudan gate sweep found that stricter size/confidence filters save only
about 6–9% of detections while losing some annotated people. The current
thresholds remain unchanged: precision rounding cuts the estimated vector
payload substantially without suppressing small detections.

Mobile reuses its parsed body indexes until a body-index write or delete changes
the in-memory DB snapshot. Desktop tracks a lightweight body-index revision in
IndexedDB and only reloads the full set when that revision changes. This avoids
re-reading and stringifying every embedding whenever body review suggestions are
requested. The app still computes matches after relevant ML or feedback changes;
no real-phone before/after timing is claimed.

A host-side synthetic review benchmark used 7,877 one-detection indexes with
the measured vectors (29.3 MB of JSON). Building the previous full review cache
key with `JSON.stringify` took 248 ms median and 262 ms p95 on this host. This
is not an Android timing; it shows the repeated work the revision cache removes.

Non-review body thumbnails reuse the existing crop memory and temporary disk
caches, isolate generator and bounded queues. In-flight body requests coalesce,
and body tasks have separate IDs from face tasks for the same file. Mobile
review previews use the existing encrypted gallery-thumbnail cache instead, as
described below. Feedback still resolves and validates current group membership
before writing anything. Desktop body crops reuse the existing `face-crops` blob
cache and object-URL lifecycle. These local caches add no image bytes to mldata.

The first uncached remote preview may still need source download and image
decoding. Matching still reads body indexes after relevant changes, and Mobile
matching runs in the Dart isolate. A follow-up can add per-file/incremental reads
and time-indexed candidate lookup. Local-only float32 BLOB/typed-array storage
can be evaluated if measured libraries still show costly local DB reads.

Mobile review retains the existing layout and controls. Body previews center the
body box and scale its longer physical side to fill the square tile. Excess
photo edges are clipped; the area outside the rounded body box is dimmed by 55%.
The bright window uses the existing thumbnail superellipse corner style. Face
previews retain their cover fit; other body thumbnail surfaces are unchanged.

A host-side synthetic review benchmark used 7,877 one-detection indexes with
the measured vectors (29.3 MB of JSON). Building the previous full review cache
key with `JSON.stringify` took 248 ms median and 262 ms p95 on this host. This
is not an Android timing; it shows the repeated work the revision cache removes.

## Review

### Mobile review loading and feedback

Both Mobile review surfaces select a fully prepared candidate before a pending
candidate, independently of whether it contains faces or bodies. Cards prefetch
two upcoming groups (one more than upstream). The independent review screen
keeps the upstream look-ahead of five groups and an eight-image budget, fitting
complete groups within that budget. A group becomes ready only after all its
representative images decode successfully. Pending work is reused; failed loads
remain retryable rather than counting as successful reviews. Stable person,
cluster and representative-file keys prevent reordered candidates from sharing
the wrong images. Undo explicitly restores the last reviewed candidate. Reloads
and disposal invalidate pending UI results.

Body review uses the gallery thumbnail download/decryption/cache path and the
body boxes already carried by suggestions. It does not fetch originals or rerun
matching merely to render a tile. Face review keeps its existing crop source.
Accept/reject metadata changes are grouped by file, read in bounded batches and
written with at most four files concurrently. Already fetched versioned metadata
can supply the first write attempt; conflicts still fetch and merge the latest
object through `FileDataService.updateFileData`. At most 200 validation snapshots
are retained. Existing/unknown subtypes and manual-assignment ownership fields
are preserved. Switching still waits for persistence, and multi-file feedback is
not a server transaction.

Run focused regressions from `mobile/apps/photos`:

```sh
flutter test --no-pub test/ui/viewer/people/review_thumbnail_queue_test.dart test/ui/viewer/people/review_thumbnail_test.dart test/models/ml/ml_metadata_update_test.dart
```

The existing Mobile suggestion views and Desktop person review dialog render
body previews in the same thumbnail positions. Face candidate generation and
ranking retain their behavior; Mobile display order can advance a ready group
as described above. A `body:` candidate reference routes
only the storage operation and crop source to the body extension.

- Accept: retain the body decision and use the existing manual-photo assignment
  operation. Face cluster assignments are not changed.
- Reject: retain a person×body decision in mldata, separate from face rejection.
- Undo/reset: remove only manual photo assignments introduced by that body
  confirmation; pre-existing manual or face assignments remain.
- Another person on Mobile: use Ente's existing person picker. A body does not
  create a new face identity.
- Removing an automatic photo from a person records a body rejection through the
  existing removal operation.

Body review candidates are groups of similar bodies proposed for the same
person. Initial grouping uses complete-link cosine similarity >=0.8, a three-hour
capture window and distinct files. It does not merge a similarity chain whose
endpoints fail the threshold. Original face suggestions keep their ordering;
body groups are appended. Normal Desktop previews show up to five crops, and
mixed-group selection loads all members. Accept, reject and reset apply to the
whole group, preserving ownership of pre-existing manual photo tags.

Human splits persist a `groupID` partition on each detection. Automatic grouping
never joins distinct explicit partitions or folds unpartitioned bodies into a
human partition. Mobile reuses the cluster gallery's mixed-grouping menu and its
existing one/multi-photo removal action; accepted body groups also appear in a
person's cluster list. Automatic mixed-group analysis uses a stricter 0.9
threshold. Isolating selected bodies removes only body-introduced assignments
and rejects the former suggested person. The existing person picker can then
assign the isolated group. Desktop provides multi-crop selection in body review
and saved choices; separating selected bodies uses the same review assignment
handler to remove introduced tags. Body partitions are never inserted into face
cluster tables. Group writes span multiple file metadata objects and the person
entity, so they are not one server transaction. MMR remains a follow-up.

Mobile face suggestion rejection also records rejected face IDs through the
existing cgroup/person sync path. Session undo removes only the rejections that
operation introduced. Face identity assignments continue to use cgroups, not a
second identity registry inside face mldata.

Manual account-backed checks: review with a mixture of cached and uncached
face/body suggestions; confirm a ready group advances before a slow one. Undo
must restore the actual previous group. Open mixed grouping, remove a member and
return to verify that it no longer appears. Check portrait/wide/edge body boxes
for matching photo and dim-window alignment. Test a larger group's accept/reject
against a throttled server and verify persistence from a second client. These
checks require a real account/device; unit tests do not establish phone latency.

## Verification

Protocol and matching tests cover time units/windows, co-occurrence, ambiguity,
human feedback and unsupported vector spaces. Review-operation tests cover
accept/reject/reset, ownership of introduced manual assignments, conflict merges
and the unchanged face-cluster path. SQLite tests cover migration and body row
lifecycle. A Mobile widget test verifies that body thumbnails retain the full
crop while face thumbnails keep their existing fit. Scheduling tests cover the
absence of body-only backfill. With `ente-ml/ml-assets`, the real-model test
exercises the pinned detector and full/partial dynamic embedding batches. Set
`ENTE_BODY_TEST_ASSETS` to an existing verified AssetStore cache for offline runs
and `ORT_DYLIB_PATH` to the platform ONNX Runtime library when needed.

Regenerate exported bindings with `cargo codegen frb photos` and
`cargo codegen napi`. Generated bindings are excluded from Git by the project's
existing code-generation workflow.

## Face model metadata

New face results record `model: mobilefacenet-portable-v1` and
`detectorModel: yolov5s-face-v1` separately from the existing indexing `version`.
Missing model identifiers on old metadata default to the current models when
read. This is a read default, not a migration/backfill of every remote object.
The original face model assets and face indexing version remain unchanged.
