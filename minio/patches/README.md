# minio-notesnook patch series

The four security fixes this fork carries, as portable patches rather than
only as commits on a branch. Apply to the pinned base, in filename order:

```bash
git checkout -b minio-notesnook RELEASE.2025-09-07T16-13-09Z
git am patches/*.patch
```

Verified: applying all four to `RELEASE.2025-09-07T16-13-09Z` (`07c3a429b`)
reproduces the `minio-notesnook` branch exactly, with zero differences in any
`.go` file. Both `git am --3way` and `git apply --check` accept them.

| File | Upstream | Fix |
|------|----------|-----|
| `01-25179bcfe-21642.patch` | #21642 | IAM sub-policy validation bypass — service account privilege escalation |
| `02-44951eba3-21612.patch` | #21612 | S3 POST policy trailing-slash bypass |
| `03-8f5489205e-21582.patch` | #21582 | LDAP TLS handshake with StartTLS |
| `04-0654eb5533-21615.patch` | #21615 | Data-scanner `timeN` closure leak |

These exist as files so the fork's entire value survives independently of this
GitHub repository — see `../HANDOFF.md`, which explains why that matters.
