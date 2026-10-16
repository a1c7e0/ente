# Repository Guidelines

## Structure and development

Ente is a monorepo: `mobile/` contains Flutter apps/packages, `web/` the npm workspace, `desktop/` the Electron client, `rust/` shared ML libraries and bindings, and `server/` the Go server. Human-facing fork instructions belong in `architecture/`; keep agent instructions in this file. Preserve upstream README content and keep its fork notice short.

Follow nearby code, naming, and tests. Use `dart format`, rustfmt, gofmt, and the repository's Prettier/ESLint configuration. Prefer established services, models, review UI, and workflows over parallel implementations. Limit unrelated refactoring and formatting; retain existing features and settings when adding body recognition.

Run focused checks for each changed area: `flutter analyze` and `flutter test` in `mobile/apps/photos`; `npm run test --workspace photos` and the relevant lint/type checks in `web`; `cargo fmt --check` and focused `cargo test -p <crate>` in `rust`; `go test ./...` in `server`. Regenerate bindings when shared Rust APIs change. Follow the repository's CI toolchain versions and pinned Action references. Add meaningful regression coverage rather than tests that repeat implementation details. Report checks that could not run.

## Branches and artifacts

`main` is the personal integration branch. Keep diagnostic and reset tools on `feat/ml-lab`; promote them only when explicitly requested. Sync upstream through normal merges and preserve fork changes. Main publishes `server`/`web`; Lab publishes `server-ml-lab`/`web-ml-lab`. Both branches have path-filtered Photos APK builds. Reuse shared build workflows, keep branch packages and tags isolated, and select the correct branch for manual builds. Artifact publishing does not deploy services.

## ML constraints

Reuse Ente's indexing, encrypted mldata synchronization, review, and mixed-grouping flows. Preserve existing face models and review operations; show body crops through existing review surfaces. Prefer conservative grouping because incorrect merges are harder to undo. Do not introduce historical bulk rescans by default or advanced anonymous/local-mode grouping and review. Explicit Lab resets must clearly state scope, process bounded batches, preserve unrelated/unknown metadata, handle conflicts and partial failures, and invalidate caches or offer reload. Avoid extra counters or diagnostic UI in ordinary product flows. Browser inference remains subject to upstream's desktop-only architecture.

See [fork testing](architecture/fork-testing.md) and [ML Lab](architecture/ml-lab.md) for operator instructions. Use concise, scoped commits and describe behavior, validation, and limitations in PRs. Never commit credentials, signing keys, or private photos.
