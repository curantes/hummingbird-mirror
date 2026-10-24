# Hardened Red Hat Hummingbird Images

Hardened container base images built on top of the upstream [Red Hat Hummingbird](https://gitlab.com/redhat/hummingbird/containers) (`registry.access.redhat.com/hi/*`) ecosystem.

## Available Image Streams

- **Static:** `ghcr.io/curantes/hardened-hummingbird-images/static:latest`
- **Core Runtime:** `ghcr.io/curantes/hardened-hummingbird-images/core-runtime:latest`

Both are published as multi-arch indexes for `linux/amd64` and `linux/arm64`.

### Tagging Convention

- `latest`: moves with every build.
- `latest-<UTC timestamp>` (e.g., `latest-20261024T213500Z`): unique per build and never overwritten.

**Pin by digest** (`image@sha256:…`) in production. Renovate keeps pinned digests current. The commit, base image and build details are recorded in the signed SLSA provenance and in the OCI labels `org.opencontainers.image.revision` and `org.opencontainers.image.base.digest`.

Images are published to GHCR only. Signatures, provenance and SBOMs are attached to the image digest in the registry; there are no GitHub Releases.

## Build Model

Images are layered on Red Hat's prebuilt Hummingbird images: each `Containerfile` pins an upstream multi-arch index by digest and adds metadata and a non-root user. Packages are not rebuilt from source here. Base image updates arrive as Renovate digest bumps.

All images build through one reusable workflow, [`build-image.yml`](.github/workflows/build-image.yml):

1. **Verify upstream:** the pinned base image's signature and SPDX SBOM attestation are verified against Red Hat release key 3 ([`policy/keys/redhat-release3.pub`](policy/keys/redhat-release3.pub)). The build fails if the base isn't pinned by digest or doesn't verify.
2. **Build, test and audit** natively on amd64 and arm64 runners: sanity tests (`images/<image>/test.sh`), a Syft SBOM, and a Grype scan of that SBOM. Grype uploads SARIF to GitHub Security and **fails the build on fixable HIGH/CRITICAL vulnerabilities**. The build also fails if Syft doesn't detect Hummingbird OS and its RPMs, because a scanner that sees no packages always reports zero vulnerabilities.
3. **Publish** (pushes to `main` and manual dispatch only): push the multi-arch index, sign it keylessly with Cosign (`--recursive`), and attest SLSA build provenance.
4. **SBOM:** generate a Syft SPDX SBOM for each platform and attest it to that platform's manifest digest.

Scheduled weekly runs re-verify the upstream image and rescan it without publishing.

## Security & Governance

- **Non-root:** runs as UID/GID `10001:10001`.
- **Signing:** keyless Cosign signatures from GitHub OIDC via the Sigstore public-good instance.
- **SLSA provenance:** GitHub artifact attestations issued to the reusable workflow identity, which meets the SLSA Build L3 isolation model. Caveat: the build workflow lives in the same repository as the images, so anyone who can push to `main` can change it. For strict L3, move `build-image.yml` into a separate, locked-down repository.
- **SBOM:** Syft `spdx-json`, one per architecture, attested as OCI referrers.
- **Pinned dependencies:** base images are pinned by digest and GitHub Actions by commit SHA, both updated by Renovate.
- **Admission control:** [`policy/verify-hummingbird-images.yaml`](policy/verify-hummingbird-images.yaml) is a Kyverno (≥ 1.13) policy that requires the Cosign signature and SLSA provenance from the build workflow on `main`.

## Verifying Images

The signer identity is the reusable build workflow:

```bash
IMAGE=ghcr.io/curantes/hardened-hummingbird-images/core-runtime:latest
IDENTITY=https://github.com/curantes/hardened-hummingbird-images/.github/workflows/build-image.yml@refs/heads/main

# Cosign signature
cosign verify "$IMAGE" \
  --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# SLSA build provenance
gh attestation verify "oci://$IMAGE" \
  --repo curantes/hardened-hummingbird-images \
  --signer-workflow curantes/hardened-hummingbird-images/.github/workflows/build-image.yml
```

SBOM attestations are attached to the per-platform manifests:

```bash
DIGEST=$(docker buildx imagetools inspect --raw "$IMAGE" \
  | jq -r '.manifests[] | select(.platform.architecture == "amd64") | .digest')

gh attestation verify "oci://${IMAGE%:*}@$DIGEST" \
  --repo curantes/hardened-hummingbird-images \
  --predicate-type https://spdx.dev/Document/v2.3
```

## Running Tests Locally

```bash
podman build -t local/static:test images/static
CONTAINER_ENGINE=podman images/static/test.sh local/static:test
```

## Why Grype (not Trivy)

Trivy doesn't recognise Hummingbird OS: it detects no OS and no packages, so it always reports zero vulnerabilities. Grype detects the `hummingbird` distro and its RPMs, and it is the scanner upstream recommends.
