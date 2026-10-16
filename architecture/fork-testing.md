# Testing this fork

## Branches and builds

`main` is the stable personal integration branch. Its Server and Web images publish as `ghcr.io/a1c7e0/server` and `ghcr.io/a1c7e0/web`. ML Lab changes live on `feat/ml-lab`; those builds publish as `ghcr.io/a1c7e0/server-ml-lab` and `ghcr.io/a1c7e0/web-ml-lab`. Both image workflows are path filtered for the server or web inputs they build. A push builds the matching branch image; a manual run builds the branch selected in the Actions UI. Builds publish a commit-SHA tag, with the branch's `latest` tag reserved for its own image name. They do not deploy to a running installation.

| Branch | Server package | Full Web package | Photos APK release |
| --- | --- | --- | --- |
| `main` | `server` | `web` | `photos-main-test` |
| `feat/ml-lab` | `server-ml-lab` | `web-ml-lab` | `photos-ml-lab-test` |

Image names above use the `ghcr.io/a1c7e0/` prefix. Pull `:latest` for the current successful build in that channel or use an immutable commit-SHA tag. The packages remain isolated even when the two branches share the same Server code. The Lab Web build enables `NEXT_PUBLIC_ENTE_ML_LAB=true` at build time; changing a running container's environment cannot enable this compiled UI.

The dedicated fork Photos APK workflow is path filtered on both branches and can also be run manually with either branch selected. It uploads branch-specific artifacts and refreshes the `photos-main-test` or `photos-ml-lab-test` prerelease. The ML Lab APK uses `io.ente.photos.dev.debug`; the main test APK uses `io.ente.photos.dev`. The fork APKs have a temporary CI signature. To install successive builds as updates, re-sign them with the same persistent local development key. The upstream Photos build workflow is separate and should be disabled in this fork's Actions settings to avoid duplicate nightly/release runs. A workflow run builds and publishes artifacts; installing an APK or replacing a container is a separate operator action.

Container images support `linux/amd64` and `linux/arm64`. Each architecture builds and runs smoke checks on a native runner; the multi-platform commit tag is published after both pass. Use the Server image with the existing [self-hosting configuration](../server/RUNNING.md), PostgreSQL, and object storage. Replacing the image does not replace those services or their configuration. The Web image includes upstream's applications on ports 3000–3010 (with 3007 omitted); set `ENTE_API_ORIGIN` to an API URL reachable from the browser. For example:

```sh
docker run --rm -p 3000:3000 \
    -e ENTE_API_ORIGIN=http://localhost:8080 \
    ghcr.io/a1c7e0/web:latest
```

Publish any additional application ports you need. The Web image retains upstream's runtime endpoint substitution.

## Workflow triggers and reuse

- Server watches `server/**`, its publishing YAML, and the shared container workflow.
- Web watches `web/**`, `rust/**`, `.dockerignore`, its publishing YAML, and the shared container workflow. Rust is a shared build input for WebAssembly.
- APK watches `mobile/apps/photos/**`, `mobile/packages/**`, the mobile workspace manifest/lockfile and analysis options, `rust/**`, Flutter setup, and its own workflow.

All three filter pushes to `main` and `feat/ml-lab`; a documentation-only commit does not trigger them. Manual dispatch bypasses path filtering and uses the selected branch. Check the workflow's `paths` for the authoritative list.

The upstream `server-publish-ghcr.yml` and `web-publish-ghcr.yml` remain the entry points. Their fork job calls `fork-publish-container.yml`, a reusable workflow added by this fork. It builds natively on amd64 and arm64, checks the images, then publishes their combined manifest. Fork jobs skip upstream schedules and official production-commit lookup. The upstream `photos-build.yml` is preserved unchanged but disabled in this fork; `fork-photos-apk.yml` builds the fork's two APK channels. GitHub Actions is the execution platform, a workflow is a YAML process, and an Action such as `actions/checkout` is one reusable step within that process.

Container builds use GitHub Actions BuildKit layer caches separated by package and architecture. Cache eviction and cold first builds are possible. APK builds reuse the existing Flutter setup cache; they do not currently persist Rust or Gradle compilation outputs. Publishing a new package does not automatically update a deployment.

## Server compatibility

Body recognition is client-side processing with encrypted mldata; it does not require a new Server API or SQL column. Using a body-capable client with an official Server does not require deploying this fork's Server image. Keep the existing database, object storage, configuration, and keys when upgrading a self-hosted Server, and back up the database before upgrading an older deployment because Museum applies included SQL migrations at startup. Accounts belong to their server; an official-cloud account is not an account on an independent self-hosted installation.

## ML testing scope

Run body inference from mobile or desktop. Photos Web retains upstream's desktop-only ML support: Web builds expose ML Lab metadata and reset controls but do not run browser inference. Mobile and desktop inference follows normal photo indexing. Missing body data alone does not start a historical rescan.

The diagnostic APK uses a separate application ID and local database; it cannot read local-only ML data from another installed app. Account-backed metadata arrives through normal encrypted sync. Anonymous local-gallery indexing can run inference and save local-gallery indexes, but grouping, crops, and review still use uploaded file IDs and the account ML database. Named people and person suggestions retain upstream account requirements. Do not extend anonymous mode with save or review operations.

For ML Lab diagnostics and reset behavior, including reset scope and confirmation text, see [ML Lab](ml-lab.md). For detector evaluation details, see [mobile ML diagnostics](ml-diagnostics.md).
