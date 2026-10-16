# ML Lab

ML Lab is the fork's development surface for inspecting and resetting body ML data. Its Android APK is a separate app with its own local database. It can coexist with the regular Photos app, but it cannot read that app's local-only indexes. Account-backed encrypted metadata syncs through the usual account flow.

## Inspect a photo

Build and install the ML Lab APK from the `feat/ml-lab` branch (see [fork testing](fork-testing.md)). Open a photo, open its details, then choose **ML detections (test build)**. The page shows stored face and body indexes for the active mode and distinguishes an absent index from an indexed photo with no detections. Face boxes are green and body boxes orange; `*` marks a body linked to a face. Scores are detector confidence values, not identity-match probabilities. Face and body boxes can be toggled independently, and the image and boxes zoom together.

**Run once (no save)** runs the current face and body pipelines for that photo without storing or uploading results and without grouping or review. It requires ML consent and local indexing, follows the existing ML lock and WebGPU policy, and may download the original photo and model assets. A busy lock is reported so the run can be retried. Trial red boxes show raw body detections excluded by the existing face-association rule. The diagnostic uses the same association function as normal indexing.

The diagnostic entry requires `--dart-define=enteMLDiagnostics=true`; it does not add boxes to the regular viewer. In the ML settings page, the existing developer options are available by tapping the enabled ML settings title seven times. Model downloads include Body Detection Model and Body Embedding Model, using the existing preload, progress, and retry flow. The shared body detector used for pet recognition downloads once.

## Reset body data

The developer options provide two resets. **Reset body review and grouping** clears review decisions, manual group splits, and rejected matches while retaining detections and embeddings. **Reset body indexes and re-run** clears detections and embeddings, then reruns body indexing; face and CLIP data and original photos remain.

Before either operation, the app gathers body indexes that match uploaded files owned by the signed-in account across the indexed library, including hidden files. The confirmation count is that target set. The operation is library-wide; it does not use the selected album as its scope. A process-wide ML lock protects the batch reset, progress is shown, and per-file failures are reported so the operation can be retried. The re-index reset forces indexing after the clear succeeds.

These controls do not start a historical rescan during ordinary use. Missing body data by itself does not trigger reprocessing; re-indexing happens only after the explicit reset. Grouping and review continue to use the existing face and body data paths and their account-backed requirements. Anonymous local-gallery indexing may store local inference results, but it does not gain person saving, suggestions, grouping, or review extensions.

The `web-ml-lab` image exposes ML Lab controls in Photos Web preferences; the `web` image retains the regular UI. Web controls operate on synchronized metadata and explicit resets; they do not run inference in the browser. Body detection and embeddings remain desktop-only. Model and detector evaluation details are in [mobile ML diagnostics](ml-diagnostics.md).
