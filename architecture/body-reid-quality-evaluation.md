# Body detection quality gate evaluation

On 2026-10-16, existing production detector outputs and a small controlled
OSNet-AIN experiment were used to compare body size, confidence and sharpness
filters. No production detector, face pipeline, matching threshold, model or
metadata format was changed. The results support testing mild size/confidence
filters; they do not support a universal hard blur cutoff or a claimed optimum.

## Data and annotation scope

The local [Penn-Fudan release](https://www.cis.upenn.edu/~jshi/ped_html/) contains
170 full images and 423 annotated people: the original 345 plus 78 instances in
`added-object-list.txt`. Its readme says small/highly occluded people were added
in this release. Generic annotation comments still warn about possible omissions;
unmatched predictions must not automatically be called false person detections.
Walking/standing instance labels and masks do not distinguish subject importance.

[Market-1501](https://arxiv.org/abs/1502.02171) supplies person crops with identity
and camera labels, including junk/distractor entries. The existing experiment
uses positive-ID `bounding_box_test` crops. These are 64×128 images, not original
full camera frames, so they cannot measure a person's original frame occupancy.
They can test how information loss affects identity matching.

## Frame occupancy

For each supplied Penn-Fudan box, measure height/image-height, box-area/image-area
and source-pixel width/height. Box area includes background within the rectangle;
it is not the visible segmentation-mask area. Annotations are read as documented
1-based inclusive pixel coordinates and converted to half-open normalized boxes.

| Annotation cohort | Count | Median relative height | Median box area | Median pixel width × height |
| --- | ---: | ---: | ---: | ---: |
| All | 423 | 70.31% | 13.04% | 101 × 287 |
| Original | 345 | 73.35% | 14.54% | 106 × 288 |
| Supplemental small/occluded | 78 | 44.54% | 4.92% | 56 × 174 |
| Largest box in each image | 170 | 77.24% | 19.86% | 123 × 291 |

The original cohort's smallest relative height is 35.93%; only 11 of all 423
annotations occupy under 1% of the frame. This dataset is dominated by large
people, so retaining its original cohort does not prove safety on distant people
in a personal photo library. All images contain people; there is no negative-image
set for measuring false alarms on scenes without people. The largest-box statistic is just a size statistic.

## Detection gate sweep

Use the first non-warmup production Rust output for each of 170 images from the
existing timing records. All three repeats have identical dimensions, face/body
boxes and scores; they are deduplicated rather than treated as 510 independent
images. Models use the verified detector and OSNet-AIN x1.0 assets documented in
[body-reid.md](body-reid.md). The archived host executable SHA-256 is
`190515ff9641b861d2ff621c9e814f14465b322f934b9f0d3d22068ab318b50f`.

Candidate gates are applied to the existing post-NMS outputs, before any proposed
embedding step. These results describe an added post-NMS quality gate, not an
exact replay of changing pre-NMS height filtering. Confidence and size sweeps,
81 exploratory combinations, scale bins and two source subsets (Penn/Fudan) are
recorded. This is an exploratory comparison without an untouched holdout set.
Predictions match ground truth one-to-one in score order at IoU >=0.5. Neither
unmatched boxes nor additional filtering are assumed to mean better ReID.

| Gate (others at baseline) | Body boxes | Removed | Matched / 423 annotations | Original matched / 345 | Supplemental matched / 78 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Current: confidence ≥0.4, height ≥12% | 563 | 0 | 415 | 343 | 72 |
| Confidence ≥0.45 | 545 | 18 | 415 | 343 | 72 |
| Confidence ≥0.5 | 527 | 36 | 414 | 342 | 72 |
| Height ≥15% | 540 | 23 | 413 | 343 | 70 |
| Confidence ≥0.45 and height ≥15% | 527 | 36 | 413 | 343 | 70 |
| Confidence ≥0.5 and height ≥15% | 511 | 52 | 412 | 342 | 70 |
| Preserve face-linked bodies; others ≥0.45 and ≥15% | 535 | 28 | 415 | 343 | 72 |
| Preserve face-linked bodies; others ≥0.5 and ≥15% | 525 | 38 | 415 | 343 | 72 |
| Box area ≥1% | 531 | 32 | 411 | 343 | 68 |
| Source box ≥64×128 pixels | 387 | 176 | 368 | 337 | 31 |
| Exploratory sharpness ≥10 | 549 | 14 | 415 | 343 | 72 |
| Exploratory sharpness ≥25 | 521 | 42 | 411 | 342 | 69 |

The 0.45/15% candidate removes 6.39% of raw bodies, losing two matched annotations
whose boxes occupy under 1% of the frame. Recall for annotations at or above 1%
area is unchanged in this sample. Increasing confidence to 0.5 loses
`PennPed00025.png`, object 1: a large box (height 83%, area 27%) with occlusion.
Visual inspection also found real people and partial/duplicate person boxes among
removed unmatched predictions; reductions must not be equated with false positives
removed. A 64×128 floor loses 47 baseline-matched annotations and is too aggressive
as a default based on these data. Relative-size rules behave differently from
absolute-pixel rules across image resolutions.

## Combine with the existing face detections

Reuse the existing face-center containment rule: multiple contained faces exclude
a body; one contained face may link to at most one body; zero faces does not
exclude a body. Filtered outputs are re-associated in their existing order, so a
face can become available when a prior body was removed. This analysis does not
change face detection or reuse aligned-face blur thresholds for bodies.

Baseline output has 302 face-linked bodies, 207 retained without a linked face,
and 54 excluded by the existing multiple-face rule. Face-linked means a potential
anchor, not an established person: identity/face-cluster assignments are not
available in this dataset, and front/back orientation is not labeled.

The following counts track the *baseline* face-associated cohorts through the
filters, separately from recomputing resulting face associations:

| Gate | Baseline face-linked kept /302 | Baseline no-linked-face kept /207 |
| --- | ---: | ---: |
| Confidence ≥0.45 | 300 | 193 |
| Confidence ≥0.5 | 293 | 185 |
| Confidence ≥0.45 and height ≥15% | 294 | 181 |
| Preserve face-linked; others ≥0.45 and ≥15% | 302 | 181 |
| Preserve face-linked; others ≥0.5 and ≥15% | 302 | 174 |
| Source box ≥64×128 | 242 | 103 |
| Sharpness ≥10 | 298 | 197 |

The existing association step retains 509 baseline bodies (373 annotation matches).
The 0.45/15% candidate retains 475 after association. Losing useful face-linked
body evidence can reduce later back-view matching, even when face recognition
itself still works. A face-aware experiment preserves all baseline face-linked bodies and applies
stricter filters only to the others. Confidence 0.5/height 15% then retains 525
raw boxes, 476 after the multi-face exclusion, and all 415 baseline annotation
matches. It preserves all 302 potential anchors and 174/207 unlinked bodies.
This uses the existing association result, not new face-quality or identity
labels. It is an offline candidate, not a production rule. Requiring a face
would defeat back-view recognition. Current Rust body inference embeds bodies before the client applies
face containment, so moving *the same* multi-face exclusion before embedding is a
separate possible computation-saving change, not included here.

## Sharpness and information-loss stress test

The exploratory body sharpness metric converts a crop to grayscale, resizes to
128×256 with PIL bilinear interpolation, then measures variance of a four-neighbor
Laplacian. It is not the existing aligned-face blur score. A synthetic blur sweep
on Penn-Fudan crops confirms this metric decreases under Gaussian blur, but that
alone does not demonstrate that low-scoring crops are useless for ReID.

A second test uses a fixed seed (`20261016`), 40 Market identities, one original
anchor and five queries per identity: 200 queries. The same 40 clean anchors remain
fixed while queries are degraded. All query identities are represented; this is a
closed-gallery stress test, without real timestamps, face detections, open-set
strangers or the full review/grouping workflow. Thresholds remain 0.74 similarity
and 0.05 margin. Two raw query re-exports exactly match their cached production
vectors; anchor self-query is 40/40. No threshold is tuned on these queries.

| Query condition | Top-1 correct /200 | Accepted correct | Accepted wrong | Unassigned |
| --- | ---: | ---: | ---: | ---: |
| Original | 172 | 94 | 2 | 104 |
| Downsample to 32×64, restore source size | 174 | 79 | 0 | 121 |
| Downsample to 16×32, restore source size | 155 | 43 | 0 | 157 |
| Gaussian blur radius 1 source pixel | 173 | 86 | 0 | 114 |
| Gaussian blur radius 2 source pixels | 165 | 52 | 0 | 148 |

All conditions use the exact same body sharpness helper as the detection sweep.
A hard sharpness ≥10 cutoff removes 10 original queries, including five correct
accepted matches, and removes neither of the two wrong accepted matches. It
removes *all* 32×64-degraded queries despite 79 correct accepted matches remaining
possible. At ≥25 it removes 54 original queries, including 12 correct accepted
matches. This small example argues against assuming that low Laplacian variance
means useless identity evidence. Texture, interpolation and source resolution
matter. The observed zero wrong matches under degradation does not establish
improved accuracy or safety; accepted coverage and the query distribution change.

## Recommendation and reproduction

Keep production defaults unchanged in this evaluation commit. The most useful
integration candidate preserves existing face-linked body evidence and tests
confidence 0.45–0.5 plus relative height 15% on unlinked bodies. In this sample,
the 0.5 face-aware variant reduces raw boxes by 6.75% and stored-eligible bodies
by 6.48%, without losing additional annotation matches. These reductions are not
proof of better identity accuracy, nor do they imply equal total runtime savings.
It is a candidate, not an optimum.
Do not adopt a universal 64×128 floor or a hard body blur cutoff from this sample.
A larger full-frame dataset or representative account-mode test photos should
cover distant subjects, high-resolution scenes and low-texture clothes before
choosing final defaults. A future change can add a post-NMS, pre-embedding body-only
quality gate without altering face/pet detection, existing review actions, or ML
metadata. Reducing boxes saves embedding/storage work; detector inference remains.

The portable sweep tool accepts saved `body_debug` JSONL or timing `records.json`:

```sh
python3 rust/tools/body-reid/evaluate_quality.py \
  --dataset /data/PennFudanPed \
  --predictions /data/body-debug.jsonl \
  --output /tmp/body-quality-results
```

Requirements: Python, NumPy, Pillow and Matplotlib; no application dependencies
are added. JSON/CSV outputs include threshold and combination sweeps, annotation
geometry, lost sample IDs, face-association cohorts, size bins, blur sensitivity,
source hashes and the plot `quality-gates.png`. The matching sanity checks cover
one-to-one matching, exact IoU=0.5 acceptance, identical/disjoint boxes and repeated
inference consistency. Dataset images, annotations, weights and private image
inspection sheets are not checked in or included in the public report.
