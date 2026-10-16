/*
This file is part of the Notesnook Sync Server project (https://notesnook.com/)

Copyright (C) 2023 Streetwriters (Private) Limited

This program is free software: you can redistribute it and/or modify
it under the terms of the Affero GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
Affero GNU General Public License for more details.

You should have received a copy of the Affero GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

using IdentityServer4;
using IdentityServer4.Models;
using Streetwriters.Common;
using System.Collections.Generic;

namespace Streetwriters.Identity
{
    public static class Config
    {
        public const string EMAIL_GRANT_TYPE = "email";
        public const string MFA_GRANT_TYPE = "mfa";
        public const string MFA_PASSWORD_GRANT_TYPE = "mfa_password";

        public const string MFA_GRANT_TYPE_SCOPE = "auth:grant_types:mfa";
        public const string MFA_PASSWORD_GRANT_TYPE_SCOPE = "auth:grant_types:mfa_password";

        public static IEnumerable<IdentityResource> IdentityResources =>
            new List<IdentityResource> {
                new IdentityResources.OpenId(),
            };

        public static IEnumerable<ApiResource> ApiResources =>
            new List<ApiResource>
            {
                new ApiResource("notesnook", "Notesnook API", new string[] { "verified" })
                {
                    ApiSecrets = { new Secret(Constants.NOTESNOOK_API_SECRET?.Sha256()) },
                    Scopes = { "notesnook.sync" }
                },
                // local API
                new ApiResource(IdentityServerConstants.LocalApi.ScopeName)
            };

        public static IEnumerable<ApiScope> ApiScopes =>
            new List<ApiScope>
            {
                new ApiScope("notesnook.sync", "Notesnook Syncing Access"),
                new ApiScope(IdentityServerConstants.LocalApi.ScopeName),
                new ApiScope("profile", "User profile information"),
                new ApiScope(MFA_GRANT_TYPE_SCOPE, "Multi-factor authentication access"),
                new ApiScope(MFA_PASSWORD_GRANT_TYPE_SCOPE, "Multi-factor authentication password step access")
            };

        // Token lifetimes.
        //
        // AbsoluteRefreshTokenLifetime was 0, which IdentityServer4 treats as
        // "no absolute limit": a sliding token that can be refreshed forever, so
        // a stolen refresh token is a permanent session that survives password
        // rotation, session revocation and every other response to a compromise.
        // There is no reason for a note-taking account to hold a 6-month
        // self-renewing credential.
        //
        // 90 days absolute still comfortably covers the client's own refresh
        // cycle (SlidingRefreshTokenLifetime 45 days means a token used at least
        // every 45 days keeps sliding) while forcing a full password login every
        // 90 days. When the absolute window expires the client must re-auth,
        // which is the intended effect.
        //
        // AccessTokenLifetime dropped from 6h to 1h. The access token is a
        // REFERENCE token validated by introspection against the identity
        // server, so it is revocable immediately regardless of lifetime -- this
        // is defence in depth for the case where the introspection cache is
        // unavailable and a token cannot be checked. 1h bounds that exposure
        // without a visible cost: the client refreshes on its own schedule and
        // the SSE/hub connections are long-lived over WebSockets, not tied to
        // access-token lifetime.
        private const int ACCESS_TOKEN_LIFETIME = 60 * 60;              // 1 hour
        private const int SLIDING_REFRESH_LIFETIME = 45 * 24 * 60 * 60; // 45 days
        private const int ABSOLUTE_REFRESH_LIFETIME = 90 * 24 * 60 * 60;// 90 days

        public static IEnumerable<Client> Clients =>
            new List<Client>
            {
                new Client
                {
                    ClientName = "Notesnook",
                    ClientId = "notesnook",
                    AllowedGrantTypes = { GrantType.ResourceOwnerPassword, MFA_GRANT_TYPE, MFA_PASSWORD_GRANT_TYPE, EMAIL_GRANT_TYPE, },
                    RequirePkce = false,
                    RequireClientSecret = false,
                    RequireConsent = false,
                    AccessTokenType = AccessTokenType.Reference,
                    AllowOfflineAccess = true,
                    UpdateAccessTokenClaimsOnRefresh = true,
                    RefreshTokenUsage = TokenUsage.ReUse,
                    RefreshTokenExpiration = TokenExpiration.Sliding,

                    AccessTokenLifetime = ACCESS_TOKEN_LIFETIME,
                    SlidingRefreshTokenLifetime = SLIDING_REFRESH_LIFETIME,
                    // Was 0 == "infinite". A stolen refresh token must not be a
                    // permanent session; see the note above the constants.
                    AbsoluteRefreshTokenLifetime = ABSOLUTE_REFRESH_LIFETIME,
                    
                    // scopes that client has access to
                    AllowedScopes = { "notesnook.sync", "offline_access", "openid", IdentityServerConstants.LocalApi.ScopeName, "mfa", "profile" },
                }
            };
    }
}