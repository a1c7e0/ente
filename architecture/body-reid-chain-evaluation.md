# Body attachment and chain evaluation (2026-10-16)

The objective is to avoid mixing identities, accepting fragmentation when the
alternative is an incorrect merge. This experiment does not change Ente's face
models, face clustering, or the default body attachment/grouping parameters.

## What upstream does

Checked upstream revision `4f6bf54b4e467c2ae6ca59cb01a0cb4817710fa6`.
Mobile `FaceClusteringService.runLinearClustering` and desktop
`clusterBatchLinear` assign a new face to the cluster of its nearest earlier
eligible face. The earlier face can itself have joined through another face.
There is no fixed hop or cluster-diameter bound in this incremental pass. Poor
face quality and explicit rejection records restrict eligible matches. The
10,000-face batches with 7,500-face offsets are not a hop limit.

Mobile's small-cluster re-clustering path additionally performs iterative
centroid-based merges; it is distinct from the main incremental pass.

The body extension previously used face-backed anchors only, and complete-link
review groups at cosine 0.8. Thus two distinct restrictions prevent chains:
new body attachments do not supply evidence, and dissimilar review-group
endpoints cannot join through a bridge. Neither restriction is changed here.

## Data and protocol

- Public Market-1501 `bounding_box_test`, from the reid-demo data-source list.
- Positive identities with at least six gallery images; sample at most 12 each:
  707 identities, 7,877 body crops. No user photos are used.
- OSNet-AIN x1.0 MSMT17, exact client asset SHA-256
  `48c2d6a6c0078e195803d130e1f9ac1fd0c048edd28ab17b57689dff8e1ac225`.
- Native Ente ONNX Runtime 1.28.1-r1, CPU, ImageNet normalization, 512-dimensional
  unit vectors. The harness implements the client's separable triangle resize;
  JPEG decoding uses Pillow. These are supplied person crops: neither detector
  errors nor real face/body association errors are included.
- Identity-disjoint tuning / validation / final-test split: 424 / 141 / 142 IDs.
  Thresholds and the recommendation were frozen before final metrics were read.
- Three repeated anchor simulations, seeds 17 / 31 / 47. Usually one virtual
  face-backed body anchor per known identity; 20% of identities have no anchor.
  These are simulated anchors, not actual detected faces.
- Primary scenario puts all split identities in one synthetic event with
  distinct file IDs. A secondary sensitivity divides them into random 30-ID
  event shards. Market has no reliable gallery wall-clock metadata, so this is
  not a validation of the real three-hour gate or group-photo co-occurrence.
- H=1 means direct root-to-body matching; H=2 and H=3 permit at most two and
  three edges from a face-backed root. Synchronous waves avoid accidental
  within-round propagation. The path score is its weakest edge; candidate
  cosine to its original root must also pass the root floor. Rival identities
  remain in margin scoring even if their route fails the root floor.
- Conservative experimental screening budgets were a 1% one-sided 95% wrong-
  attachment bound and at most 2% polluted known identities, checked per seed.
  These are study objectives, not proven product guarantees. Repeated seeds
  reuse images and are not independent people; pooled bounds are not evidence
  of meeting a per-seed requirement.

## Fixed strict parameters

The independently selected H1/H2/H3 configurations all use cosine >=0.84,
best-minus-runner-up >=0.16, and root cosine >=0.63. No configuration met every
screening constraint. These rows are an offline comparison, not permission to
auto-propagate.

Final held-out test, three repeated simulations combined:

| Max root-relative edges | Correct / all attachments | Wrong | Correct known-query coverage |
| --- | ---: | ---: | ---: |
| 1 | 380 / 380 | 0 | 10.92% |
| 2 | 471 / 471 | 0 | 13.53% |
| 3 | 492 / 492 | 0 | 14.13% |

Zero observed mistakes do not establish a <1% error rate: the worst per-seed
one-sided upper bounds are 2.28%, 1.94%, and 1.84%, respectively. H4 adds only
three further correct attachments; unbounded propagation adds none beyond H4.

Validation already showed the risk: H1 had 0/424 wrong attachments, H2 had
5/555, and H3 had 14/583. The final random 30-ID event sensitivity, with separately sampled virtual
anchors inside each shard, also exposes errors. This changes both the anchor
sample and candidate pool; it is not a causal estimate of event size alone:

| Max edges | Correct / all attachments | Wrong share |
| --- | ---: | ---: |
| 1 | 619 / 624 | 0.80% |
| 2 | 838 / 850 | 1.41% |
| 3 | 882 / 911 | 3.18% |

At the old 0.74/0.05 gates, final wrong shares are 11.71%, 17.34%, and 20.08%
for H1/H2/H3. These severe synthetic-event results are not an estimate of a
user's real album error rate; they show that a hop limit alone is insufficient.

## Upstream-style baseline, retuned for body features

This baseline copies the main nearest-earlier-face decision rule and strict
threshold comparison, with the upstream most-recent-prior tie rule. Every body
crop becomes evidence; unmatched crops start experimental body-only clusters.
Face blur/pose quality gates cannot be simulated from these crops. It does not
create body-only person records in the client.

The face default distance 0.24 corresponds to cosine >0.76. The offline sweep
retuned cosine thresholds from 0.74 through 0.94; the minimum-risk pre-test
fallback was >0.90. Neither setting met every screening constraint.

| Body-vector cosine | Wrong known-person claims / all claims | Correct known-query coverage | Pair precision | Mixed non-singleton groups |
| --- | ---: | ---: | ---: | ---: |
| >0.76 reference | 766 / 2,579 (29.70%) | 52.08% | 54.94% | 140 / 667 |
| >0.90 retuned | 0 / 210 | 6.03% | 100% observed | 0 / 651 |

The retuned baseline fragments each test identity into about 8.89 groups on
average, versus 2.88 at the impure reference setting. Its 95% error upper bounds
are 3.39-4.06% per seed because known-person claims are few. Tuning had observed
errors even at >0.90; the final zero does not certify safety. Experimental
body-only clustering and seeded person attachment have different output types;
pair/group statistics and known-person claims are deliberately reported
separately rather than treated as interchangeable coverage scores.

## Result and implementation boundary

For a precision-first policy, this study does not support enabling third-hop
automatic identity assignment, or blindly copying upstream face linkage with
body features. Two-hop suggestions are a more promising next step than third-
hop automatic assignments, but must remain reviewable and must not bypass human
splits, same-photo conflicts, rejections, or the root-relative time window.
This study has not calibrated review-group linkage: complete-link review
boundaries remain unchanged. The current shipping defaults remain unchanged;
0.84/0.16 is an offline high-precision candidate, not a production guarantee.

Separate fixes on this branch let existing high-confidence body matches appear
in account-mode unnamed face-cluster galleries and details, and preserve
unnamed-cluster removals with stable anchor face references. The later local-mode
matching extension has been reverted; local mode retains basic body inference
and storage only. These changes add no local-only naming/review controls, model changes,
historical rescan, or new count UI.

Validation: Photos analyze passed; 13 relevant Flutter regressions passed;
22 web body/review/unnamed-membership tests passed; ente-new TypeScript checks
passed. Host benchmark self-checks cover hop bounds, canonical matrix/record
alignment, nearest-prior ties, strict threshold equality, root-floor competitor
scoring, and order-independent bounded waves. No new Android APK or real-device
validation has been performed for this branch.

The corrected scripts, frozen configurations and raw statistics are available
in the [reproduction archive](https://github.com/a1c7e0/ente/releases/download/photos-ml-diagnostics-2026-10-16/body-chain-evaluation-2026-10-16.zip).
It contains no dataset images or weights. The existing release APK predates
these account-mode unnamed-cluster fixes.
