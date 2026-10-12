# Body recognition in Photos

Body recognition adds evidence for photos without a usable face. It does not
change face or CLIP models, their indexing versions, or face clustering. Mobile
and Desktop share the Rust detector and embedding implementation.

## Models

The human detector uses class 0 of Ente's existing, pinned
`yolov5s_object_fp16.onnx` asset. Body embeddings use the public
`osnet_ain_x1_0_msmt17.onnx` export of the same official MSMT17 checkpoint
used by reid-demo. Both assets go through AssetStore. The embedder is about
8.7 MB; it expects ImageNet-normalized RGB CHW crops of 128×256 pixels and
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
Face/CLIP indexing versions stay unchanged.

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
Review writes refetch and merge after 409 conflicts. A body producer adopts an
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

Remote body changes have a separate status-diff cursor that fetches metadata
only for existing local body rows, so completed body indexes can receive decisions
from another device without fetching every historical photo's mldata. Mobile body-sync failures
do not fail the original file-data sync. Log out and ML database clearing remove
body rows; deleted/missing files are excluded from matching and body rows are
pruned through file-data deletion and existing cleanup paths.

## Matching

Body samples are anchored to face identities through geometric face containment.
Only face-backed samples supply identity evidence. Unknown face clusters still
compete in the ambiguity calculation, but are not promoted into named people by
the body layer. Body-derived attachments do not seed face clustering or become
new body anchors.

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

## Review

The existing Mobile suggestion views and Desktop person review dialog render
body crops in the same thumbnail positions. The original face suggestions,
sorting and handlers retain their behavior. A `body:` candidate reference routes
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

The current body candidates are individual detections. MMR and grouping body
candidates for fewer review interactions are deliberately separate follow-ups;
this change does not alter the original review ranking.

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
