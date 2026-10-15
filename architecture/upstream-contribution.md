# Preparing an upstream contribution

This is a preparation plan for this fork. No upstream proposal or submission
branch has been created. Keep the working fork and its published images intact.

## Start from upstream

Create a separate branch from the then-current `ente/ente` main branch when the
contribution is ready. A separate worktree keeps this work away from the fork's
deployment branch. Do not rebase or force-push the fork's working `main`.

```sh
git fetch upstream main
git worktree add -b upstream/body-reid ../ente-body-reid-upstream upstream/main
```

Do not submit the fork's full history or blindly cherry-pick its merge commits.
The feature commits combine protocol, inference and UI work; extract their final
changes into reviewable commits on the new base. Retain regression fixes and
tests, including the four internal-only Web export fixes from `313ba22658`.

The initial inventory compares upstream `4f6bf54b4e` with fork `05b37f0413`.
Refresh that comparison before starting: upstream may already contain equivalent
fixes, and schema versions and generated bindings must match the new base.

## Discuss scope before proposing UI changes

Upstream's [contribution guide](https://github.com/ente/ente/blob/main/CONTRIBUTING.md)
says: "For anything that changes UX, however small, please talk to us" and asks
contributors not to open large product-change PRs. A future discussion should
describe body crops in existing review, mixed grouping, model download costs,
and the unchanged face models and indexing schedule. No discussion is posted as
part of this preparation.

Possible review units, subject to maintainer agreement:

1. Shared ML metadata merge/retry handling and face model identifiers, with
   unknown-field and conflict tests. Extract this independently of body review.
2. Body inference, model assets, versioned metadata and local database support,
   including Rust, FRB and NAPI boundaries and normal indexing scheduling.
3. Body matching, grouping and existing review/mixed-grouping integration on
   mobile and desktop, including crop display and feedback tests.

The ONNX Runtime setup fixes in `9ec2c3f505` and `cdb0dca61b` can be considered
separately if upstream still needs them. Do not mix fork deployment changes into
these fixes. MMR and historical rescanning are not part of this implementation.

## Separate feature changes from fork operations

Include the relevant final changes in `desktop/`, `mobile/`, `rust/`, `web/`, and
`architecture/body-reid.md`, with their tests and lint exception explanations.
Regenerate bindings using upstream's code-generation commands when required.

Exclude the fork container publisher, changes to Server/Web GHCR workflows,
`architecture/fork-testing.md`, and this preparation guide. `web/Dockerfile`
has been restored to upstream's original full-image definition. APK test-builder
changes live on the separate
`build/photos-arm64-test` branch and should also stay out of a contribution.
Repository Actions settings, caches, GHCR packages and releases are not Git
changes and are not transferred by creating a new branch.

Treat model distribution as a separate decision. The pinned export tool is
useful provenance, but `.github/workflows/body-reid-models.yml` is restricted to
this fork. The asset URL in `rust/crates/ml/src/body.rs` points to this fork's
release. Before upstream integration, agree on model hosting, verify the pinned
checkpoint's redistribution terms, and update the URL, size and checksum
together if the artifact changes. Do not replace it with an unpublished URL.

## Candidate patch and verification

A candidate source patch can be generated without changing either branch:

```sh
git diff --binary upstream/main main -- \
    desktop mobile rust web architecture/body-reid.md \
    ':(exclude)web/Dockerfile' > /tmp/body-reid-candidate.patch
```

This is a starting inventory, not a submission-ready patch: it still includes
the fork model URL and spans the proposed review units. Apply it to a new
upstream-based branch only when ready, then split it and review the complete
diff. A patch applying cleanly does not establish behavioral compatibility.

Run affected-area CI on the final integration and preserve successful results
when only retrying a failed infrastructure check. Include metadata round trips,
conflict handling, schema migrations, model/vector compatibility, grouping,
accept/reject/undo/split behavior, and scheduling regression tests. Validate both
clients on devices and supply before/after review screenshots as requested by
upstream. Current automated CI and container checks do not replace device tests
or model-quality measurements on a representative photo set.
