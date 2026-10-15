# Testing this fork

## Container images

The Server and Web GHCR workflows build this fork's commits when relevant changes
reach `main`. Both also support manual dispatch. Forks skip the upstream release
schedules and production commit selection.

After a successful build, this fork publishes:

```sh
docker pull ghcr.io/a1c7e0/server:latest
docker pull ghcr.io/a1c7e0/web:latest
```

Both images support `linux/amd64` and `linux/arm64`. Each architecture builds and
runs smoke checks on a native runner. The combined commit-SHA tag and `latest`
are published only after both jobs pass. Manual builds of other branches publish
their commit-SHA tag without changing `latest`.

Use the Server image with the existing [self-hosting configuration](../server/RUNNING.md),
including PostgreSQL and object storage. Replacing the image does not replace
those services or their configuration.

The Web image includes the same applications as upstream's default Docker image:

| Application | Port |
| --- | --- |
| Photos | 3000 |
| Accounts | 3001 |
| Albums | 3002 |
| Auth | 3003 |
| Cast | 3004 |
| Share | 3005 |
| Embed | 3006 |
| Paste | 3008 |
| Locker | 3009 |
| Memories | 3010 |

Set `ENTE_API_ORIGIN` to an API
URL reachable from the browser, for example:

```sh
docker run --rm -p 3000:3000 \
    -e ENTE_API_ORIGIN=http://localhost:8080 \
    ghcr.io/a1c7e0/web:latest
```

For another device, use the server's reachable address instead of `localhost`.
The image retains upstream's Dockerfile and runtime endpoint substitution. The
Web publisher builds all applications in that Dockerfile. The retired
Photos-only package and Docker target have been removed. Publish the additional
ports you need when running the full image.

These workflows use persistent GitHub Actions BuildKit layer caches, separated
by image and architecture. Cache export includes intermediate stages. The first
build is cold, and GitHub may evict caches. BuildKit cache mounts inside a
Dockerfile, such as the Server's Go compiler cache, are not exported by this
configuration. The Android APK workflow currently caches the Flutter SDK, but
does not persist Gradle or Rust compilation outputs between its builds.

## Server replacement and client compatibility

At upstream snapshot `4f6bf54b4e`, this fork's `server/` tree is identical to
upstream. Body recognition adds client-side processing and an encrypted mldata
subtype, not a new server API or SQL column. Using these clients with an official
server does not require deploying the fork Server image. Official clients can
use this server through their existing self-hosting endpoint configuration, but
do not implement body inference or body review.

Changing a self-hosted Server image is a normal upstream upgrade: retain the
existing PostgreSQL database, object storage, configuration and keys. Back up
the database before upgrading an older deployment because Museum applies its
included SQL migrations at startup. The fork's main snapshot need not equal the
commit used by the official production image.

Accounts belong to their server; an official-cloud account does not become an
account on an independent self-hosted installation. Current upstream clients
preserve unknown top-level mldata fields on normal writes, but legacy writers
and concurrent stale writes do not provide a universal preservation guarantee.
These compatibility findings are based on code and protocol inspection, not
device testing against an official-cloud account.

The fork's container workflows publish images to GHCR; they do not deploy them
to a running server. Historical GitHub deployment records from disabled upstream
deployment workflows do not need to be enabled to use these images.

## Body recognition testing

Use the mobile or desktop client to run body inference. Photos Web in a browser
retains upstream's desktop-only ML support; a Web container does not run the
models on the server.

On mobile, anonymous local-gallery indexing can download the models, run body
inference, and store results in the local-gallery ML database. Body matching,
grouping, crops, and review currently still use uploaded file IDs and the account
ML database. Anonymous body review is therefore not supported yet. Upstream also
requires an account for saving named people and person suggestions. This fork
retains those account requirements and does not extend anonymous mode with
person saving or review operations that upstream does not support.

Model downloads require network access initially. Body inference accompanies
normal photo indexing: missing body data alone does not trigger historical
rescanning. For an account-backed review test, use newly indexed photos with
face-backed person anchors and similar outfits within the matching time window.
