# Standing risk: IdentityServer4 4.1.2 is end-of-life

**Status:** accepted for now, migration planned. This file is the record of that
decision so it is not rediscovered as a surprise later.

## The facts

`Streetwriters.Identity/Streetwriters.Identity.csproj` pins:

```xml
<PackageReference Include="IdentityServer4" Version="4.1.2" />
```

IdentityServer4 was the Apache-2.0 predecessor to Duende IdentityServer. Its
final release was **4.1.2, in 2020**. There has been no further release since.
Duende IdentityServer, the successor, is commercially licensed and is a
different package with a different API surface.

This service is the authentication core of the whole stack: signup, sign-in,
2FA, refresh tokens, token introspection for the notes API and the SSE hub, and
session revocation all run through it. Every one of those paths is only as
patched as a framework that stopped shipping patches in 2020.

The five related packages are pinned to the same generation:

| Package | Version |
|---|---|
| `IdentityServer4` | 4.1.2 |
| `IdentityServer4.AspNetIdentity` | 4.1.2 |
| `IdentityServer4.EntityFramework` | 4.1.2 |
| `Streetwriters.IdentityServer4.Contrib.MongoDB` | 5.0.0 |
| `Streetwriters.IdentityServer4.KeyRack` | 0.2.0 |

The MongoDB persistence layer is a third-party community package built against
IdentityServer4 4.x, so the migration is not confined to this repository.

## What has been done instead

Since no upstream patch will ever arrive, the mitigations that do not depend on
the framework were applied instead:

- Argon2id password hashing (`PasswordHelper.cs`, 64 MiB / t=3) rather than the
  ASP.NET Identity default.
- 5-attempt lockout with a 5-minute window, and `AccessFailedAsync` on **every**
  failed 2FA code, so OTP guessing is bounded by the same lockout.
- `AbsoluteRefreshTokenLifetime` is now 90 days instead of 0. The previous
  setting made a stolen refresh token a permanent session that survived every
  other response to a compromise.
- Access token lifetime reduced from 6 hours to 1 hour.
- Enrollment, confirmation and password-reset email addresses every action, so
  a compromised token is at least visible to the account owner.

None of that fixes a vulnerability in the framework. It lowers the value of the
stolen material.

## Why the migration is not trivial

1. **Licensing.** Duende IdentityServer requires a paid licence for production
   use. There is a free tier for small deployments, and that has to be
   evaluated before the work starts, not after.
2. **`Streetwriters.IdentityServer4.KeyRack` is an abandoned 0.2.0 package.**
   Duende's replacement is `Duende.IdentityServer.KeyManagement`. The signing-key
   storage on the `keystore-data` volume has to move, and that is the volume
   whose loss logs every user out.
3. **`Streetwriters.IdentityServer4.Contrib.MongoDB` targets 4.x.** The
   persisted grants and configuration stores have to be swapped.
4. **The passwordless-login protocol is in the clients, not here.** The custom
   `email` / `mfa` / `mfa_password` extension grants are implemented against
   IdentityServer4's `IExtensionGrantValidator`. Duende has a different
   extension point, and changing the response contract would break every
   installed Notesnook client that speaks it.

## What would trigger doing it now rather than later

- A published CVE in IdentityServer4 that is reachable from this stack's
  configuration.
- A Duende licence acceptable for a self-hosted deployment.
- Either of the above becoming true means this file gets deleted in favour of
  the migration branch.

## Interim rule for contributors

Do not add new surface to this service. Every feature request that would extend
IdentityServer4 usage widens the blast radius of staying on an EOL framework,
and the rewrite cost with it. Anything that touches
`Streetwriters.Identity/Validation/`, `Config.cs` clients, or
`Streetwriters.Identity/Services/TokenGenerationService.cs` should be treated as
migration-hostile code.