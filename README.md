# Hummingbird Mirror

[![Mirror](https://github.com/curantes/hummingbird-mirror/actions/workflows/mirror.yml/badge.svg?branch=main)](https://github.com/curantes/hummingbird-mirror/actions/workflows/mirror.yml?query=branch%3Amain)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

An independent mirror of [Red Hat® Hardened Images](https://gitlab.com/redhat/hummingbird/containers) (Project Hummingbird, `registry.access.redhat.com/hi/*`). **This project has no affiliation with Red Hat, LLC and is not endorsed or supported by Red Hat.** The checks described below are our own.

Images are **not rebuilt**. This pipeline verifies, tests and scans each approved upstream digest, then copies it to the mirror unchanged: same digest, with the Red Hat signatures and attestations. We then attach our own signed approval, a SLSA verification summary attestation (VSA). The VSA records that our checks passed; it is not a statement by Red Hat.

## Available Images

All images are multi-arch (`linux/amd64`, `linux/arm64`) under `ghcr.io/curantes/hummingbird-mirror/`. They are grouped by the categories of the Red Hat [Hummingbird catalog](https://images.redhat.com/) and sorted alphabetically within each group.

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

### Database & Data Management

| Image | Tags | Contents | User |
|---|---|---|---|
| `etcd` | `3.7` | etcd, etcdctl and etcdutl; client port 2379, peer port 2380, data in `/var/lib/etcd`; distroless, no shell | 65532 |
| `etcd` | `3.7-builder` | the above plus bash, curl and dnf | 65532 |
| `valkey` | `9.0` | Valkey server and CLI on port 6379, data in `/data`; runs without a configuration, so protected mode refuses remote clients until you set a password (`--requirepass`) or mount one; ships bash | 65532 |
| `valkey` | `9.0-builder` | the above plus curl and dnf | 65532 |

### Developer Tools

| Image | Tags | Contents | User |
|---|---|---|---|
| `curl` | `8.23` | curl with HTTP/2 and OpenSSL, and the system CA trust store; the entrypoint is `curl`; distroless, no shell | 65532 |
| `curl` | `8.23-builder` | the above plus bash and dnf | 65532 |
| `git` | `2.56` | git with HTTP(S) and SSH remotes; the entrypoint is `git`, working directory `/git`; ships bash, less and the ssh client; the image has no passwd entry for 65532, so for SSH remotes mount an `/etc/passwd` with one (Podman adds it automatically, Docker and Kubernetes don't) | 65532 |
| `git` | `2.56-builder` | the above plus curl and dnf | 65532 |

### Messaging

| Image | Tags | Contents | User |
|---|---|---|---|
| `rabbitmq` | `4.3` | RabbitMQ broker and CLI tools; AMQP on 5672, data in `/var/lib/rabbitmq` (keep the hostname stable, it names the node and its data directory); `guest` only works from inside the container; plugins such as `rabbitmq_management` ship but are disabled, and `/etc/rabbitmq` isn't writable, so mount an `enabled_plugins` file to enable them; ships bash | 65532 |
| `rabbitmq` | `4.3-builder` | the above plus curl and dnf | 65532 |

### Networking

| Image | Tags | Contents | User |
|---|---|---|---|
| `coredns` | `1.15` | CoreDNS; without a Corefile, answers `whoami` on port 53; pass `-conf` to use a mounted Corefile; the binary has no file capabilities, so port 53 needs unprivileged low ports (Docker's default; with Podman add `--sysctl net.ipv4.ip_unprivileged_port_start=0`); distroless, no shell | 65532 |
| `coredns` | `1.15-builder` | the above plus bash, curl and dnf | 65532 |

### Web Services

| Image | Tags | Contents | User |
|---|---|---|---|
| `haproxy` | `3.0` | HAProxy (LTS); ships no configuration, mount one at `/usr/local/etc/haproxy/haproxy.cfg`; distroless, no shell | `haproxy` (999) |
| `haproxy` | `3.0-builder` | the above plus bash, curl and dnf | `haproxy` (999) |
| `nginx` | `1.30` | nginx serving a default page on port 8080; configuration in `/etc/nginx/conf.d/`; distroless, no shell | 65532 |
| `nginx` | `1.30-builder` | the above plus bash, curl and dnf | 65532 |

The approved set is defined in [`mirror/images.yaml`](mirror/images.yaml).

## Usage

### Tagging Convention

- `<stream>[-variant]` (e.g. `1.26`, `21-runtime`, `latest`): moves to each newly approved digest.
- `<version>[-variant]` (e.g. `1.26.10`, `21.0.12-runtime`): the upstream version. It can move when Red Hat rebuilds the same version.
- `<version or stream>[-variant]-<UTC timestamp>` (e.g. `1.26.10-20261024T213500Z`): unique per approval and never overwritten.

**Pin by digest** (`image@sha256:…`) in production. The mirrored digest is identical to the upstream digest, so the Red Hat catalog, CVE and VEX data apply to it directly.

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

1. **Verify upstream:** the source must be pinned by digest to a multi-arch index (amd64 and arm64). The Red Hat signature and SPDX SBOM attestation must verify against an upstream key in [`policy/keys/`](policy/keys), today Red Hat release key 3 ([`redhat-release3.pub`](policy/keys/redhat-release3.pub)). The upstream version must belong to the tag's stream (`go:1.26` must contain 1.26.x).
2. **Test and scan** natively on amd64 and arm64:
   - sanity tests from `tests/<name>/test.sh`
   - a Syft SBOM, with a check that Hummingbird OS and its RPMs are detected
   - a Grype scan and the vulnerability gate described below
3. **Promote** (on `main` only: manual runs, and pushes and scheduled runs for entries whose stream tag doesn't point at the pinned digest yet):
   1. Copy the image by digest with `regctl image copy --referrers`, plus the upstream cosign `.sig`/`.att`/`.sbom` tags. This keeps their Sigstore bundle referrers, including the SBOM attestation that cosign 3 verifies.
   2. Re-verify the copy against the Red Hat release key.
   3. Attest a VSA (`https://slsa.dev/verification_summary/v1`).
   4. Only then move the tags.

A digest that fails is never promoted: the tags stay on the last approved digest. Scheduled weekly runs re-verify and rescan every entry, and promote the ones that pass and aren't on the mirror yet.

PRs and pushes to `main` check entries whose source or `tests/<name>/` changed; changes to the pipeline (the workflows, `.github/scripts/` or `policy/keys/`) check every entry. Pushes also retry every entry whose stream tag on the mirror doesn't point at its pinned digest yet, so a failed or cancelled promotion is picked up by the next push or the next weekly run. A manual run checks and promotes every entry.

### Vulnerability Gate

The gate counts **fixable HIGH and CRITICAL** findings: Grype matches of that severity for which a fixed package version exists. What it requires depends on the baseline, the digest the mirror stream tag (e.g. `go:1.27`) points at when the run starts. That is the image you keep getting if the pinned digest is rejected.

| Mode | When | Requirement |
|---|---|---|
| `new-stream` | the stream tag doesn't exist yet | no fixable HIGH/CRITICAL findings |
| `refresh` | the stream tag points at another digest | no fixable HIGH/CRITICAL finding that the baseline doesn't have |
| `audit` | the stream tag already points at the pinned digest | none; findings are reported in the run summary |

A refresh is compared with the baseline because upstream rebuilds often still carry a few fixable findings. Rejecting such a rebuild would leave the mirror on the older digest, which has more. Both images are scanned in the same job with the same Grype database, and a finding is identified by vulnerability ID, package name and package type, so a package update that still carries the same CVE isn't counted as new. The logic lives in [`.github/scripts/vuln-gate.sh`](.github/scripts/vuln-gate.sh) and has fixture tests.

The weekly run reports the findings of approved digests without failing on them. It still fails, and opens a `mirror-alert` issue, when a signature, a test or package detection fails.

Renovate keeps the digests in `mirror/images.yaml` current. It only refreshes digests and never moves an entry to another stream. Each entry gets its own PR, which merges automatically once the checks pass, so an image that fails doesn't hold back the others. Updates to the actions and tools the mirror workflows use are not merged automatically: the VSA is trusted because `verify-promote.yml` on `main` signs it, so those changes get a review.

### Upstream Keys

The pipeline tries every `policy/keys/*.pub` and accepts an image when one of them verifies its signature, and one its SBOM attestation ([`verify-upstream.sh`](.github/scripts/verify-upstream.sh)). That allows a key rotation without a gap. When a new Red Hat release key is announced:

1. Add the new public key as `policy/keys/<name>.pub`. Take it from the Red Hat [product signing keys](https://access.redhat.com/security/team/key) page and check its fingerprint there. Keep the old key: digests that are already mirrored are signed with it.
2. Add the same key to both Kyverno policies, so that either key is enough. The `Policy Keys` check fails until each policy and `policy/keys/` contain the same keys.
   - [`verify-hummingbird-mirror-ivp.yaml`](policy/verify-hummingbird-mirror-ivp.yaml): add another attestor and list it next to the existing one in the first validation (`[attestors.redhatRelease3, attestors.<new>]`).
   - [`verify-hummingbird-mirror.yaml`](policy/verify-hummingbird-mirror.yaml): add another `- keys:` entry to the first attestor set and set `count: 1` on that set.
3. Open a PR. A change under `policy/keys/` re-checks every entry, and the `Policy` workflow tests the policy in a cluster.
4. Tell consumers to update their copy of the policy they use.

Remove the old key, in both places, only when no mirrored digest you still support is signed with it.

### Why Grype (not Trivy)

Trivy doesn't recognise Hummingbird OS: it detects no OS and no packages, so it always reports zero vulnerabilities. Grype detects the `hummingbird` distro and its RPMs, and it is the scanner upstream recommends.

## Verifying Images

```bash
IMAGE=ghcr.io/curantes/hummingbird-mirror/go:1.27

# The original Red Hat signature and SBOM attestation (on the mirror)
cosign verify --key policy/keys/redhat-release3.pub --insecure-ignore-tlog "$IMAGE"
cosign verify-attestation --key policy/keys/redhat-release3.pub --insecure-ignore-tlog --type spdx "$IMAGE"

# Our approval (VSA)
gh attestation verify "oci://$IMAGE" --bundle-from-oci \
  --repo curantes/hummingbird-mirror \
  --signer-workflow curantes/hummingbird-mirror/.github/workflows/verify-promote.yml \
  --predicate-type https://slsa.dev/verification_summary/v1
```

The VSA lists what was checked in `verifiedLevels`: `UPSTREAM_SIGNATURE_VERIFIED`, `UPSTREAM_SBOM_ATTESTATION_VERIFIED`, `SANITY_TESTS_PASSED`, and either `NO_FIXABLE_HIGH_OR_CRITICAL_VULNERABILITIES` (new stream) or `NO_VULNERABILITY_REGRESSION` (refresh). Its `vulnerabilityGate` field records the gate mode, the baseline digest, and the Grype version and database build date of each architecture's scan.

Two Kyverno policies enforce both checks at admission. Install the one that fits your Kyverno version, not both:

| Kyverno | Policy | Type |
|---|---|---|
| 1.20 and later | [`policy/verify-hummingbird-mirror-ivp.yaml`](policy/verify-hummingbird-mirror-ivp.yaml) | `ImageValidatingPolicy` |
| 1.13 to 1.19 | [`policy/verify-hummingbird-mirror.yaml`](policy/verify-hummingbird-mirror.yaml) | legacy `ClusterPolicy`, which Kyverno 1.20 no longer accepts |

Both require the Red Hat signature and a VSA with `verificationResult: PASSED`, and neither looks at the levels.

## Known Limitations

- The Red Hat SLSA provenance on `registry.access.redhat.com` can't be verified with their published keys. We verify their signature and SBOM attestation instead.
- The VSA records our checks as custom `verifiedLevels`. We don't claim an upstream SLSA build level.
- A mirrored image can have fixable HIGH/CRITICAL vulnerabilities. A refresh only has to be no worse than the digest it replaces, and vulnerabilities disclosed after promotion don't remove an image. Scan the digests you deploy.
- The VSA means "passed our checks at promotion time". It doesn't expire and isn't withdrawn when new vulnerabilities are disclosed. VSAs issued before the regression gate carry `NO_FIXABLE_HIGH_OR_CRITICAL_VULNERABILITIES` and no `vulnerabilityGate` field.
- The Kyverno policy hasn't been tested in a cluster yet.

## Running Tests Locally

```bash
CONTAINER_ENGINE=podman tests/openjdk/test.sh registry.access.redhat.com/hi/openjdk:25-runtime 25-runtime
```

## Trademarks

Red Hat is a trademark of Red Hat, LLC, registered in the United States and other countries. Red Hat product names, such as Red Hat Hardened Images, are used here only to identify the upstream images, following the Red Hat [trademark guidelines](https://www.redhat.com/en/about/trademark-guidelines-and-policies).

The mirrored images are unmodified Red Hat images. They are distributed under the Red Hat Universal Base Image (UBI) EULA referenced in their `com.redhat.license_terms` label. This repository's Apache-2.0 license covers only its own code and configuration.
