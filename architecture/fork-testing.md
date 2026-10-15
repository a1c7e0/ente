# Testing this fork

## Container images

The Server and Web GHCR workflows build this fork's commits when relevant changes
reach `main`. Both also support manual dispatch. Forks skip the upstream release
schedules and production commit selection.

After a successful build, this fork publishes:

```sh
docker pull ghcr.io/a1c7e0/server:latest
docker pull ghcr.io/a1c7e0/photos-web:latest
```

Both images support `linux/amd64` and `linux/arm64`. Each architecture builds and
runs smoke checks on a native runner. The combined commit-SHA tag and `latest`
are published only after both jobs pass. Manual builds of other branches publish
their commit-SHA tag without changing `latest`.

Use the Server image with the existing [self-hosting configuration](../server/RUNNING.md),
including PostgreSQL and object storage. Replacing the image does not replace
those services or their configuration.

The Photos Web image serves Photos on port 3000. Set `ENTE_API_ORIGIN` to an API
URL reachable from the browser, for example:

```sh
docker run --rm -p 3000:3000 \
    -e ENTE_API_ORIGIN=http://localhost:8080 \
    ghcr.io/a1c7e0/photos-web:latest
```

For another device, use the server's reachable address instead of `localhost`.
The image retains upstream's runtime endpoint substitution. The default
`web/Dockerfile` target still builds all upstream Web apps; `--target photos`
builds only Photos.

These workflows use persistent GitHub Actions BuildKit layer caches, separated
by image and architecture. Cache export includes intermediate stages. The first
build is cold, and GitHub may evict caches. BuildKit cache mounts inside a
Dockerfile, such as the Server's Go compiler cache, are not exported by this
configuration. The Android APK workflow currently caches the Flutter SDK, but
does not persist Gradle or Rust compilation outputs between its builds.

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
