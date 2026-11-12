# Security Policy

This repository mirrors Red Hat® Hardened Images unchanged. It is an independent project with no affiliation with Red Hat, LLC. See the [README](README.md) for what the pipeline checks.

## Reporting a Problem

Report security problems with the mirror privately: open the repository's [Security tab](https://github.com/curantes/hummingbird-mirror/security) and choose **Report a vulnerability**. Please don't open a public issue.

Problems with the mirror include:

- a mirrored image whose digest, signature or attestations differ from upstream
- a tag that points at a digest without a verification summary attestation (VSA)
- a weakness in the workflows, the vulnerability gate or the Kyverno policy
- anything that would let someone else publish to the mirror or sign a VSA

Vulnerabilities in the software inside the images are not ours to fix, because the images are not rebuilt. Report those to the Red Hat Product Security team (<secalert@redhat.com>). The mirror picks up a fix once a rebuilt upstream image passes the checks.

This is a volunteer project without a guaranteed response time.

## What the Approval Covers

The VSA records that an image passed our checks when it was promoted. It doesn't expire and isn't withdrawn when new vulnerabilities are disclosed. A mirrored image can therefore have known vulnerabilities; see "Vulnerability Gate" and "Known Limitations" in the README. Scan the digests you deploy.

## Retention

- **Approved digests** stay on the mirror after their stream tag moves to a newer digest. Nothing deletes them, and there is no cleanup job.
- **Timestamp tags** (`<version or stream>[-variant]-<UTC timestamp>`) are created once per approval and never overwritten or deleted.
- **Stream and version tags** (`1.27`, `1.27.3`) move to each newly approved digest.

No retention period is guaranteed. If you need an image to stay available, pin it by digest and keep your own copy.

## Trademarks

Red Hat is a trademark of Red Hat, LLC, registered in the United States and other countries.
