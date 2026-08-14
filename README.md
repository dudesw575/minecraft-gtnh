# minecraft-gtnh

Version-aware Docker images for the [GT New Horizons](https://www.gtnewhorizons.com/) Minecraft 1.7.10 server.

[![Build GTNH Docker image](https://github.com/dudesw575/minecraft-gtnh/actions/workflows/docker-image.yml/badge.svg?branch=main)](https://github.com/dudesw575/minecraft-gtnh/actions/workflows/docker-image.yml)

## What this builds

This repository builds `dudesw575/mc-gtnh` from the **official GTNH SERVER distribution**. It does not use the GTNH source/modpack repository archive as the server payload.

The current GTNH distribution exposes Java 17-25 server ZIPs from the official downloads site and version history. At the time this automation was implemented, the current stable release was 2.8.4

The workflow fails rather than falling back to a mirror or GitHub source archive if the expected official server ZIP is unavailable.

## Release channels

| Channel | Discovery | Moving tags |
|---|---|---|
| `stable` | Latest stable release from GTNH version history | `latest`, `major.minor` |

Every successful build also gets an immutable full-version tag.

Examples:

```text
dudesw575/mc-gtnh:2.8.4
dudesw575/mc-gtnh:2.8
dudesw575/mc-gtnh:latest
```

## Runtime

The image uses Java 21, which is within GTNH's currently recommended Java 17-25 range. The image retains the official server pack's startup arguments and dynamically determines the server JAR from the packaged Linux startup script instead of embedding a Forge filename in the Dockerfile.

Memory is configurable at runtime and defaults to 6 GB:

```bash
docker run -d \
  --name gtnh \
  -e EULA=TRUE \
  -e MEMORY=12G \
  -p 25565:25565 \
  -v gtnh-data:/minecraft \
  dudesw575/mc-gtnh:latest
```

`EULA=TRUE` is required for a new deployment. The EULA file, server properties, configuration, world data, logs, and other normal runtime state are stored under `/minecraft` so replacing the image does not replace the world.

The immutable GTNH application payload lives under `/opt/gtnh` inside the image. The `/minecraft` volume is state, not the application payload.

### Docker Compose

The repository includes a minimal `docker-compose.yml`:

```bash
docker compose up -d
```

Adjust `MEMORY` in the Compose file to suit the host.

### Configuration updates

The `config` directory is persisted as runtime state. This is intentional: users frequently customize GTNH configuration, and silently replacing it during an image update would be destructive.

If you intentionally want to regenerate the packaged default configuration after an update, stop the server and remove only the persisted config directory before starting the new image. Back it up first.

## Automation

`.github/workflows/docker-image.yml` runs daily and also supports `workflow_dispatch`.

Manual inputs:

- `channel`: `stable`, `beta`, or `nightly`
- `version`: optional exact GTNH version

If `version` is omitted, the latest version for the selected channel is discovered automatically.

If `version` is supplied, the workflow still verifies that the official GTNH server ZIP exists before doing anything else.

Before a build, the workflow checks Docker Hub for the immutable full-version tag. If that tag already exists, the build is skipped. This prevents the daily schedule from rebuilding the same upstream release.

## Build safety

A release is published only after all of these succeed:

1. Official GTNH version discovery.
2. Official server-pack URL validation.
3. Server ZIP download.
4. SHA-256 calculation; if GTNH publishes a checksum sidecar, it is compared and a mismatch fails the workflow.
5. ZIP extraction and server-pack structure validation.
6. Dynamic discovery of the packaged server launcher/JAR.
7. Docker image build.
8. GTNH server smoke test.
9. High/Critical vulnerability scan with Trivy, ignoring only vulnerabilities for which no fix is available.
10. Docker Hub login and tag publication.

The smoke test accepts the EULA only inside CI, starts the server with 6 GB, waits up to 15 minutes for the normal `Done (` ready message, checks that the process remains alive, and probes TCP port 25565 while starting. Server logs are uploaded when the job finishes so startup failures can be diagnosed.

No Minecraft client or player login is required for the smoke test.

## Reproducibility

The Docker build records:

- GTNH version
- official server-pack filename
- server-pack URL
- downloaded server-pack SHA-256
- source repository
- Git revision
- build timestamp

The build uses BuildKit cache exports and pins the GitHub Actions used for checkout, artifact transfer, Docker Buildx/QEMU, Docker Hub login, and Trivy to reviewed commit SHAs.

The GTNH ZIP is supplied to BuildKit as a secret file so the archive is not copied into the Docker build context or retained as a normal image layer.

## Required GitHub configuration

Create a Docker Hub access token with permission to push to `dudesw575/mc-gtnh` and add it to the repository as:

```text
DOCKERHUB_TOKEN
```

The workflow uses the repository owner (`dudesw575`) by default. If you prefer a different Docker Hub username, create a repository variable named `DOCKERHUB_USERNAME`.

No Snyk token is required. The old optional Snyk integration was removed because the release gate is now a single deterministic Trivy scan.

## First test

After merging the workflow, use **Actions → Build GTNH Docker image → Run workflow**.

For the first controlled build, use:

- Channel: `stable`
- Version: `2.8.4`

This exercises explicit-version validation rather than relying on the discovery result.

After that succeeds, run it again with the version field empty. The workflow should discover the current stable version and skip the build if its immutable Docker Hub tag has already been published.

To test prereleases, manually select `beta` or `nightly`. Do not use a beta/nightly tag as a production world without backing up the world first.

## Updating a running server

Pull the new image and restart the container:

```bash
docker pull dudesw575/mc-gtnh:latest
docker compose up -d
```

The image contains the new immutable server application while the `/minecraft` volume retains the world and runtime state.

Always back up the GTNH world before moving between pack versions. GTNH versions must match between the server and clients.
