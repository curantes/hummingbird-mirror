# Hummingbird Mirror

[![Mirror](https://github.com/curantes/hummingbird-mirror/actions/workflows/mirror.yml/badge.svg?branch=main)](https://github.com/curantes/hummingbird-mirror/actions/workflows/mirror.yml?query=branch%3Amain)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

An independent mirror of [Red Hat Hardened Images](https://gitlab.com/redhat/hummingbird/containers) (Project Hummingbird, `registry.access.redhat.com/hi/*`). **This project is not affiliated with, endorsed by or supported by Red Hat.** The checks described below are our own.

Images are **not rebuilt**. This pipeline verifies, tests and scans each approved upstream digest, then copies it to the mirror unchanged: same digest, with Red Hat's signatures and attestations. We then attach our own signed approval, a SLSA verification summary attestation (VSA). The VSA records that our checks passed; it is not a statement by Red Hat.

## Available Images

All images are multi-arch (`linux/amd64`, `linux/arm64`) under `ghcr.io/curantes/hummingbird-mirror/`. They are grouped by the categories of Red Hat's [Hummingbird catalog](https://images.redhat.com/) and sorted alphabetically within each group.

### Operating System

| Image | Tags | Contents | User |
|---|---|---|---|
| `core-runtime` | `latest` | glibc runtime with bash | 65532 |
| `static` | `latest` | CA certificates, tzdata; no shell, no libc | 65532 |

### Programming Languages & Runtimes

| Image | Tags | Contents | User |
|---|---|---|---|
| `go` | `1.26`, `1.27` | Go toolchain, gcc, git, make | root |
| `go` | `1.26-builder`, `1.27-builder` | the above plus dnf | root |
| `nodejs` | `24`, `26` | Node.js with npm and npx; ships bash (`docker-entrypoint.sh`) | 65532 |
| `nodejs` | `24-builder`, `26-builder` | the above plus dnf | 65532 |
| `openjdk` | `21`, `25` | JDK (javac, jshell) | 65532 |
| `openjdk` | `21-runtime`, `25-runtime` | headless JRE; distroless, no shell | 65532 |
| `openjdk` | `21-builder`, `25-builder` | JDK plus bash and dnf | 65532 |
| `php` | `8.5` | PHP CLI with common extensions; ships bash | root |
| `php` | `8.5-builder` | the above plus Composer and dnf | root |
| `php` | `8.5-fpm` | PHP-FPM on port 9000; distroless, no shell or CLI | 65532 |
| `php` | `8.5-fpm-builder` | PHP-FPM plus PHP CLI, Composer, bash and dnf | 65532 |
| `python` | `3.11`–`3.15` | CPython with pip and venv; distroless, no shell | 65532 |
| `python` | `3.11-builder`–`3.15-builder` | the above plus bash and dnf | 65532 |
| `rust` | `1.99` | Rust toolchain (cargo, clippy, rustfmt), gcc, git, make | root |
| `rust` | `1.99-builder` | the above plus dnf | root |

The approved set is defined in [`mirror/images.yaml`](mirror/images.yaml).

## Usage

### Tagging Convention

- `<stream>[-variant]` (e.g. `1.26`, `21-runtime`, `latest`): moves to each newly approved digest.
- `<version>[-variant]` (e.g. `1.26.10`, `21.0.12-runtime`): the upstream version. It can move when Red Hat rebuilds the same version.
- `<version or stream>[-variant]-<UTC timestamp>` (e.g. `1.26.10-20261024T213500Z`): unique per approval and never overwritten.

**Pin by digest** (`image@sha256:…`) in production. The mirrored digest is identical to Red Hat's, so Red Hat's catalog, CVE and VEX data apply to it directly.

### Typical Multi-Stage Builds

```dockerfile
# Go: build with the toolchain, run on static
FROM ghcr.io/curantes/hummingbird-mirror/go:1.27 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/app .

FROM ghcr.io/curantes/hummingbird-mirror/static:latest
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
```

```dockerfile
# Java: build with the JDK, run on the distroless JRE
FROM ghcr.io/curantes/hummingbird-mirror/openjdk:25-builder AS build
# ... build your jar with Maven/Gradle ...

FROM ghcr.io/curantes/hummingbird-mirror/openjdk:25-runtime
COPY --from=build /build/target/app.jar /app/app.jar
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

## Pipeline

[`mirror.yml`](.github/workflows/mirror.yml) reads the allowlist and runs [`verify-promote.yml`](.github/workflows/verify-promote.yml) for every entry:

1. **Verify upstream:** the source must be pinned by digest to a multi-arch index (amd64 and arm64). Red Hat's signature and SPDX SBOM attestation must verify against Red Hat release key 3 ([`policy/keys/redhat-release3.pub`](policy/keys/redhat-release3.pub)). The upstream version must belong to the tag's stream (`go:1.26` must contain 1.26.x).
2. **Test and scan** natively on amd64 and arm64:
   - sanity tests from `tests/<name>/test.sh`
   - a Syft SBOM, with a check that Hummingbird OS and its RPMs are detected
   - a Grype gate that **fails on fixable HIGH/CRITICAL vulnerabilities**
3. **Promote** (pushes to `main` and manual dispatch only):
   1. Copy the image by digest with `regctl image copy --referrers`, plus Red Hat's cosign `.sig`/`.att`/`.sbom` tags. This keeps their Sigstore bundle referrers, including the SBOM attestation that cosign 3 verifies.
   2. Re-verify the copy against Red Hat's key.
   3. Attest a VSA (`https://slsa.dev/verification_summary/v1`).
   4. Only then move the tags.

A digest that fails is never promoted: the tags stay on the last approved digest. Scheduled weekly runs re-verify and rescan every approved digest without promoting.

PRs and pushes to `main` only check entries whose source or `tests/<name>/` changed; changes to the pipeline or `policy/keys/` check every entry. A manual run checks and promotes every entry, which also retries a failed promotion.

Renovate keeps the digests in `mirror/images.yaml` current. It only refreshes digests and never moves an entry to another stream.

### Why Grype (not Trivy)

Trivy doesn't recognise Hummingbird OS: it detects no OS and no packages, so it always reports zero vulnerabilities. Grype detects the `hummingbird` distro and its RPMs, and it is the scanner upstream recommends.

## Verifying Images

```bash
IMAGE=ghcr.io/curantes/hummingbird-mirror/go:1.27

# Red Hat's original signature and SBOM attestation (on the mirror)
cosign verify --key policy/keys/redhat-release3.pub --insecure-ignore-tlog "$IMAGE"
cosign verify-attestation --key policy/keys/redhat-release3.pub --insecure-ignore-tlog --type spdx "$IMAGE"

# Our approval (VSA)
gh attestation verify "oci://$IMAGE" --bundle-from-oci \
  --repo curantes/hummingbird-mirror \
  --signer-workflow curantes/hummingbird-mirror/.github/workflows/verify-promote.yml \
  --predicate-type https://slsa.dev/verification_summary/v1
```

[`policy/verify-hummingbird-mirror.yaml`](policy/verify-hummingbird-mirror.yaml) is a Kyverno (≥ 1.13) policy that enforces both checks at admission.

## Known Limitations

- Red Hat's SLSA provenance on `registry.access.redhat.com` can't be verified with their published keys. We verify their signature and SBOM attestation instead.
- The VSA records our checks as custom `verifiedLevels`. We don't claim an upstream SLSA build level.
- The Kyverno policy hasn't been tested in a cluster yet.

## Running Tests Locally

```bash
CONTAINER_ENGINE=podman tests/openjdk/test.sh registry.access.redhat.com/hi/openjdk:25-runtime 25-runtime
```

## Trademarks

Red Hat is a trademark or registered trademark of Red Hat, Inc. or its subsidiaries in the United States and other countries. Red Hat and its product names, such as Red Hat Hardened Images, are used here only to identify the upstream images, following Red Hat's [trademark guidelines](https://www.redhat.com/en/about/trademark-guidelines-and-policies). The mirrored images are Red Hat's unmodified images and remain subject to Red Hat's terms; this repository's Apache-2.0 license covers only its own code and configuration.
