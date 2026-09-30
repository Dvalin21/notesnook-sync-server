# minio-notesnook patch series

The five patches this stack carries, as portable files rather than only as
commits on a branch. The first four are upstream security fixes; the fifth is
ours and is not in any upstream repository. Apply to the pinned base, in filename order:

```bash
git checkout -b minio-notesnook RELEASE.2025-09-07T16-13-09Z
git am patches/*.patch
```

Verified: applying all five to `RELEASE.2025-09-07T16-13-09Z` (`07c3a429b`)
applies cleanly, in filename order, with no fuzz.

| File | Upstream | Fix |
|------|----------|-----|
| `01-25179bcfe-21642.patch` | #21642 | IAM sub-policy validation bypass — service account privilege escalation |
| `02-44951eba3-21612.patch` | #21612 | S3 POST policy trailing-slash bypass |
| `03-8f5489205e-21582.patch` | #21582 | LDAP TLS handshake with StartTLS |
| `04-0654eb5533-21615.patch` | #21615 | Data-scanner `timeN` closure leak |
| `05-cve-2026-40344-2026-41145.patch` | **ours, no upstream fix exists** | Signature verification on the `STREAMING-UNSIGNED-PAYLOAD-TRAILER` write path |

`05` is not an upstream patch. Upstream is archived and no patched
open-source release exists for CVE-2026-40344 or CVE-2026-41145; the fix ships
only in commercial MinIO AIStor. See the comment in the patch itself.

These exist as files so the entire local delta survives independently of any
GitHub repository. That is now the only place the patches are needed: the
image is built from upstream plus these files, and references no fork.
