# Testing this fork

## Branches and builds

`main` is the stable personal integration branch. Its Server and full Web images publish as `ghcr.io/a1c7e0/server` and `ghcr.io/a1c7e0/web`. ML Lab diagnostics and mobile reset controls live on `feat/ml-lab`. Separate `server-ml-lab`/`web-ml-lab` packages and Web reset controls are deferred; Lab APKs use the same Server as regular clients. Container publishing is restricted to `main`, including manual dispatch.

| Branch | Server package | Full Web package | APK release |
| --- | --- | --- | --- |
| `main` | `server` | `web` | `photos-main-test` |
| `feat/ml-lab` | Uses main's Server | Uses main's Web | `photos-ml-lab-test` |
| `feat/face-profile-review` | Uses main's Server | Uses main's Web | `photos-face-profile-review-test` |
| `feat/integration-test` | Uses main's Server | Uses main's Web | `photos-integration-test` |

Image names use the `ghcr.io/a1c7e0/` prefix. Pull `:latest` for the current successful main build or use a commit-SHA tag for a fixed version. Workflow runs publish artifacts; they do not deploy to a running installation.

The dedicated fork Photos APK workflow runs only by manual dispatch, with `main`, `feat/ml-lab`, `feat/face-profile-review`, or `feat/integration-test` selected. All supported branches build Photos only for arm64. Pushes do not trigger APK builds. It uploads branch-specific artifacts and refreshes that branch's test prerelease. The ML Lab and Photos integration APKs use `io.ente.photos.dev.debug`; the main and profile-review test APKs use `io.ente.photos.dev`. To install successive builds as updates, configure the repository Actions secrets `PHOTOS_TEST_KEYSTORE_BASE64`, `PHOTOS_TEST_KEYSTORE_PASSWORD`, `PHOTOS_TEST_KEY_PASSWORD`, and `PHOTOS_TEST_KEY_ALIAS` for one persistent test keystore. Until those secrets are present, a manual run warns and uses a temporary signature. Main and ML Lab have different application IDs; profile-review shares the main test application ID. The upstream Photos build workflow is separate and should be disabled in this fork's Actions settings to avoid duplicate nightly/release runs. A workflow run builds and publishes artifacts; installing an APK or replacing a container is a separate operator action.

The supplied persistent test keystore uses alias `ente-photos-test`, also the workflow default. Set `PHOTOS_TEST_KEY_ALIAS` explicitly when using a different keystore alias. The workflow validates the keystore password and alias immediately after JDK setup, before generating bindings or compiling the APK.

Container images support `linux/amd64` and `linux/arm64`. Each architecture builds and runs smoke checks on a native runner; the multi-platform commit tag is published after both pass. Use the Server image with the existing [self-hosting configuration](../server/RUNNING.md), PostgreSQL, and object storage. Replacing the image does not replace those services or their configuration. The Web image includes upstream's applications on ports 3000–3010 (with 3007 omitted); set `ENTE_API_ORIGIN` to an API URL reachable from the browser. For example:

```sh
docker run --rm -p 3000:3000 \
    -e ENTE_API_ORIGIN=http://localhost:8080 \
    ghcr.io/a1c7e0/web:latest
```

Publish any additional application ports you need. The Web image retains upstream's runtime endpoint substitution.

The integration branch combines Photos profile review, automatic unnamed people, and ML Lab. Tap the Machine Learning page title seven times for the existing main menu (including purge/reset, remote fetch, interaction processing, and clustering thresholds), plus the unnamed-person threshold. Full ML controls and body resets are under **Settings → ML Debug**; there is no separate ML Lab tools entry. Manual dev-flavor APK builds pass `--dart-define=enteDeveloperTools=true` to show the Debug entry in signed-in account mode without changing internal-user flags. This remains a release build, not Flutter debug mode. See the [Chinese integration checklist](integration-test-checklist.zh.md) for UI entry points and expected results. Locker shared-storage client and Server changes are isolated on `feat/locker-shared-storage` and are not part of this integration branch. Previously published integration APKs predate this separation; check their source commit before testing.

## Workflow triggers and reuse

- Server watches `server/**`, its publishing YAML, and the shared container workflow.
- Web watches `web/**`, `rust/**`, `.dockerignore`, its publishing YAML, and the shared container workflow. Rust is a shared build input for WebAssembly.
- APK builds are manual-only because native builds are slow; they do not watch pushes or schedules.

Container workflows filter pushes to `main`; documentation-only commits do not trigger builds. APK dispatch uses the selected supported test branch; container dispatch is restricted to main. Check the workflow's `paths` for the authoritative list.

The upstream `server-publish-ghcr.yml` and `web-publish-ghcr.yml` remain the entry points. Their fork job calls `fork-publish-container.yml`, a reusable workflow added by this fork. It builds natively on amd64 and arm64, checks the images, then publishes their combined manifest. Fork jobs skip upstream schedules and official production-commit lookup. The upstream `photos-build.yml` is preserved unchanged but disabled in this fork; `fork-photos-apk.yml` builds the fork's supported test APK channels. GitHub Actions is the execution platform, a workflow is a YAML process, and an Action such as `actions/checkout` is one reusable step within that process.

Container builds use GitHub Actions BuildKit layer caches separated by package and architecture. Cache eviction and cold first builds are possible. Manual APK builds reuse the Flutter SDK, Dart package downloads, Gradle dependency/build caches, Cargo downloads, and compiled Rust outputs (both host code generation/tests and Cargokit Android arm64 builds). Rust output caches are separated by APK channel and keyed by runner image, compiler version, build configuration, dependency manifests/lockfiles, and commit. Compatible earlier commits can be restored; the existing upstream helper restores timestamps only for unchanged Rust source content. Rust incremental artifacts and host debug symbols are disabled to limit cache size. Signing keys and the collected APK artifact directory are excluded from the explicit cache paths. The first build fills these caches; toolchain changes or cache eviction can still cause a cold build, and speedup depends on the changed code. Publishing a new package does not automatically update a deployment.

## Server compatibility

Body recognition is client-side processing with encrypted mldata; it does not require a new Server API or SQL column. Using a body-capable client with an official Server does not require deploying this fork's Server image. Keep the existing database, object storage, configuration, and keys when upgrading a self-hosted Server, and back up the database before upgrading an older deployment because Museum applies included SQL migrations at startup. Accounts belong to their server; an official-cloud account is not an account on an independent self-hosted installation.

## ML testing scope

Run body inference from mobile or desktop. Photos Web retains upstream's desktop-only ML support: Web builds retain the regular UI and do not add reset controls or browser inference. Mobile and desktop inference follows normal photo indexing. Missing body data alone does not start a historical rescan.

The diagnostic APK uses a separate application ID and local database; it cannot read local-only ML data from another installed app. Account-backed metadata arrives through normal encrypted sync. Anonymous local-gallery indexing can run inference and save local-gallery indexes, but grouping, crops, and review still use uploaded file IDs and the account ML database. Named people and person suggestions retain upstream account requirements. Do not extend anonymous mode with save or review operations.

On mobile, the ML debug page's **Auto-create unnamed people** threshold defaults to 10 distinct uploaded owner photos; set it to 0 to disable. After a normal ML run or manual clustering command, the app considers only existing unassigned clusters and creates at most 10 unnamed people in that pass. Creation uses encrypted cgroup sync and excludes face IDs already assigned in synced person feedback. These unnamed people can be reviewed and renamed through the existing People flows.

Concurrent devices can briefly create duplicate people because cgroup creation has no idempotency key. After ordinary cgroup sync, the client reconciles only untouched automatic people whose original and current face sets match exactly, even if their cluster IDs differ. The lexicographically smallest person ID survives. Other copies become empty hidden records through the existing version-checked entity update, not deletion; their local mappings are removed on receiving devices.

Person edits permanently clear creation provenance; body review claims that provenance with a version precondition before writing feedback. Named, edited, overlapping, legacy, and body-referenced people are preserved. Partial overlaps are never merged automatically. Failed cleanup retries on subsequent syncs, including empty diffs. These are client-side convergence guards, not a transaction spanning multiple people or body metadata; offline and concurrent canonical edits can still require manual review. The setting does not alter face clustering or auto-merge thresholds and does not trigger historical image reindexing.

The experiment lives on `feat/auto-unnamed-person`, with focused verification on relevant pushes. It uses optional `isUnnamed`, `autoCreationFaceIDs`, and `autoDuplicateOf` person metadata fields; clients without support for `isUnnamed` treat empty-name people as ignored. Legacy ignored people remain ignored. APK builds remain manual.

For ML Lab diagnostics and reset behavior, including reset scope and confirmation text, see [ML Lab](ml-lab.md). For detector evaluation details, see [mobile ML diagnostics](ml-diagnostics.md).

## Profile-face review experiment

The `feat/face-profile-review` branch adds high-quality pose-only singleton faces directly to Ente's existing manual review suggestions. A candidate must pass the existing blur/score rules, have detection score strictly above 0.8, match a person's cached reference centroid within 0.65 cosine distance, and be at least 0.15 closer than every other person's reference clusters. It is shown for human review without waiting for the usual review mean/median thresholds; accepting or rejecting it still uses Ente's existing review actions. Per-person rejection and same-photo conflicts still suppress a candidate. The per-person page can show all qualifying groups; the global review route keeps its existing sampled-person limit and adds at most one qualifying side-face group per selected person.

Automatic clustering distances (0.24/0.16), face models, embeddings, encrypted metadata, and review operations remain unchanged. Missing, stale, or invalid reference summaries suppress the extra candidates; no historical rescan is started. Desktop review retains its existing behavior.

The cached-centroid policy was checked on held-out CFP profiles using five ordering seeds. Requiring a 0.15 person-distance gap yielded 25–27 correct side-singleton matches per seed and no wrong matches in this small cohort. Candidates then enter manual review directly, so these counts do not measure user decisions or real-library accuracy. Raw tightly cropped CFP profiles rarely passed detection; real-device validation remains necessary.

Run the focused mobile tests from `mobile/apps/photos`:

```sh
flutter test --no-pub test/services/machine_learning/profile_review_test.dart test/db/ml_profile_review_test.dart
```

Run the Rust database guard test from `rust`:

```sh
cargo test --locked -p ente-photos --lib profile_review_keeps_quality_and_singleton_guards
```
