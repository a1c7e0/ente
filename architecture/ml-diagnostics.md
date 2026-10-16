# Mobile ML detection diagnostics

This testing work lives on `dev/ml-detection-inspector`. It does not enable
internal-user features or change review, grouping, historical indexing, or
anonymous-mode account requirements.

## On a phone

The diagnostic APK is named **Ente ML Lab**, with package ID
`io.ente.photos.dev.debug`, using upstream's registered development-debug
client configuration. It installs alongside the previous Ente Dev APK
and official Photos. Android keeps each application's local database separate;
the Lab cannot read another application's local-only ML data. Account-backed
metadata can be received through the normal encrypted sync flow.

Open a photo, open its details, and select **ML detections (test build)**.
The page reads existing face/body indexes from the database for the active mode.
It distinguishes a missing index from an indexed image with zero detections.
Faces are green, retained bodies orange, and `*` marks a body linked to a face.
Scores are detector confidences, not identity-match probabilities. Toggle either
box type independently and pinch to zoom the image and boxes together.

**Run once (no save)** runs the current face and body pipelines on this photo.
It requires ML consent and local indexing, respects the existing process-wide ML
lock and WebGPU policy, and does not save, upload, group, or review the result.
It may download the original image and models. A busy ML lock is reported so the
user can retry. In trial mode, red boxes show raw body detections excluded by the
existing face-association rule (more than one face center inside a body box).
The same association function is used by normal indexing and diagnostics.

The page is gated by `--dart-define=enteMLDiagnostics=true`. Without that opt-in,
the photo details entry is absent. It does not add overlays to the normal viewer.
The developer options already provided by upstream remain accessible by tapping
the enabled ML settings title seven times; they do not provide this box viewer.

The existing model download status now includes Body Detection Model and Body
Embedding Model. Body assets use the same preloading/progress/retry flow as face
and CLIP assets. The body detector shared with pet recognition is downloaded
once. A snapshot of progress covers fast downloads before the settings page
subscribes. Unknown download sizes show activity instead of a percentage.

## Building

The branch's manual Photos workflow builds only an arm64 Android APK, runs
Photos analysis and the diagnostic/body regression tests, and verifies model
download selection. Its temporary CI signature is an intermediate build
signature. The delivery APK is re-signed with the persistent local development
keystore, outside Git, so subsequent delivery builds can use the same identity.
Do not use the raw CI candidate to update a delivery APK. The old Ente Dev APK's
temporary signing key was not retained; do not uninstall it to install the Lab.

The build uses the supported Linux x86_64 Android toolchain to cross-compile
arm64 machine code. It does not execute an emulated ARM Android system. The
Photos workflow is kept disabled on the default branch between manual tests to
avoid activating upstream nightly/release automation.

## Host-side inference checks

Run the production Rust face/body pipelines without writing client ML metadata:

```sh
cd rust
cargo run --locked -p ente-ml --example body_debug -- /path/to/assets photo.jpg
```

The example uses the repository's pinned ONNX Runtime loader and model catalog.
It prints JSON lines containing image dimensions, normalized boxes, detector
scores, embedding dimensions/norms, and combined face/body inference time.
It does not print identity embeddings or implement a second detector.

On 2026-10-15, the complete [Penn-Fudan pedestrian dataset](https://www.cis.upenn.edu/~jshi/ped_html/)
was tested locally: 170 images and 423 boxes from the supplied annotation files.
With the existing detector thresholds and greedy score-ordered matching at
IoU >= 0.5, 415 annotated boxes were matched (98.1% recall). There were 563 raw
body detections, with mean matched IoU 0.900. All body embeddings had 512 finite
values and unit norm within 1e-5; all boxes were within [0, 1]. Normal face
association retained 509 body detections and excluded 54 ambiguous detections.

The annotation-match fraction was 73.7%. The release contains 345 original
annotations plus 78 supplemental small/occluded people. Its readme describes the
supplemental labels, while generic annotation comments still warn about possible
omissions. Unmatched boxes can include real people, partial/duplicate boxes and
false detections; they must not all be counted as false person detections. See the
[quality-gate evaluation](body-reid-quality-evaluation.md) for size distributions,
face-association stratification and threshold comparisons. These numbers describe the raw
detector on this dataset, not mobile stored-index recall or general accuracy.
The dataset is not an identity-labeled ReID evaluation; it does not establish
body grouping, review accuracy, or phone battery/performance characteristics.
Dataset images and annotations are not checked into this repository.

A blank image produced zero faces/bodies. An upright JPEG and a corresponding
counter-rotated JPEG with EXIF orientation 6 both decoded to 559 x 536 with two
faces and two bodies. Corresponding body box IoUs exceeded 0.997. Flutter widget
tests cover letterboxing, portrait/landscape viewports, shared image/box zoom
containment, and labels at image edges, including a tiny viewport.
