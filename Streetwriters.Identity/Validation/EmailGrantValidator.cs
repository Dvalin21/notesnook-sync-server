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

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using IdentityServer4;
using IdentityServer4.Models;
using IdentityServer4.Stores;
using IdentityServer4.Validation;
using Microsoft.AspNetCore.Identity;
using AspNetCore.Identity.Mongo.Model;
using Streetwriters.Common;
using Streetwriters.Common.Enums;
using Streetwriters.Common.Models;
using Streetwriters.Identity.Enums;
using Streetwriters.Identity.Extensions;
using Streetwriters.Identity.Interfaces;
using Streetwriters.Identity.Models;
using static IdentityModel.OidcConstants;

namespace Streetwriters.Identity.Validation
{
    public class EmailGrantValidator : IExtensionGrantValidator
    {
        private UserManager<User> UserManager { get; set; }
        private SignInManager<User> SignInManager { get; set; }
        private IMFAService MFAService { get; set; }
        private ITokenGenerationService TokenGenerationService { get; set; }
        private IResourceStore ResourceStore { get; set; }
        private IUserClaimsPrincipalFactory<User> PrincipalFactory { get; set; }
        private ITemplatedEmailSender EmailSender { get; set; }
        private RoleManager<MongoRole> RoleManager { get; set; }

        public EmailGrantValidator(
            UserManager<User> userManager,
            SignInManager<User> signInManager,
            IMFAService mfaService,
            ITokenGenerationService tokenGenerationService,
            IResourceStore resourceStore,
            IUserClaimsPrincipalFactory<User> principalFactory,
            ITemplatedEmailSender emailSender,
            RoleManager<MongoRole> roleManager)
        {
            UserManager = userManager;
            SignInManager = signInManager;
            MFAService = mfaService;
            TokenGenerationService = tokenGenerationService;
            ResourceStore = resourceStore;
            PrincipalFactory = principalFactory;
            EmailSender = emailSender;
            RoleManager = roleManager;
        }

        public string GrantType => Config.EMAIL_GRANT_TYPE;

        // Burn a comparable amount of CPU to the existing-user path below (a
        // claim lookup plus response construction). A caller who measures can
        // otherwise tell "no such account" from "account exists" by response
        // time even though both take one Mongo round trip.
        //
        // Fixed 5000 SHA-256 rounds: enough to match the claim-scan cost, cheap
        // enough that it cannot itself become a denial-of-service lever. The
        // input mixes the submitted address with a per-process salt so the
        // result cannot be precomputed by an attacker, and the loop cannot be
        // optimised away because the accumulator is consumed afterwards.
        private static readonly byte[] TimingSalt =
            System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);

        private static void EqualizeTiming()
        {
            var acc = new byte[32];
            System.Buffer.BlockCopy(TimingSalt, 0, acc, 0, 32);
            for (var i = 0; i < 5000; i++)
            {
                acc = System.Security.Cryptography.SHA256.HashData(acc);
            }
            // Keep the result observable so the JIT cannot elide the loop.
            System.Threading.Volatile.Write(ref TimingSink, acc[0]);
        }

        private static byte TimingSink;


        public async Task ValidateAsync(ExtensionGrantValidationContext context)
        {
            var email = context.Request.Raw["email"];
            var clientId = context.Request.ClientId;
            var existingUser = await UserManager.FindRegisteredUserAsync(email, clientId);
            if (existingUser == null)
            {
                // ponytail: login must never manufacture accounts. Unknown
                // emails fail here (upstream behavior); accounts - and their
                // confirmation mail - come only from explicit signup.
                //
                // The user lookup is a Mongo round trip either way, but the
                // existing-user path below additionally reads the MFA config and
                // builds a response object. Equalise that with a comparable
                // amount of work before returning, so response TIME does not
                // disclose whether an address is registered. This closes the
                // timing side of the oracle.
                //
                // NOT closed by this: the RESPONSE SHAPE still differs (a known
                // address gets an MFA-scoped token plus additional_data, an
                // unknown one gets invalid_grant). Removing that requires
                // changing the passwordless-login contract the Notesnook clients
                // implement, so it is a protocol change, not a patch. See the
                // "Account enumeration" entry in PRODUCTION-READINESS.md.
                EqualizeTiming();
                context.Result = new GrantValidationResult(TokenRequestErrors.InvalidGrant);
                return;
            }

            var user = existingUser;

            var isMultiFactor = await UserManager.GetTwoFactorEnabledAsync(user);
            var primaryMethod = isMultiFactor ? MFAService.GetPrimaryMethod(user) : MFAMethods.Email;
            var secondaryMethod = MFAService.GetSecondaryMethod(user);
            var sendPhoneNumber = primaryMethod == MFAMethods.SMS || secondaryMethod == MFAMethods.SMS;

            context.Result.CustomResponse = new Dictionary<string, object>
            {
                ["additional_data"] = new MFARequiredResponse
                {
                    // Single backslash in BOTH places. This read `@"\d(?!\\d{0,3}$)"`, and in a
                // verbatim C# string `\\` is two characters, so the lookahead
                // was "not followed by a literal backslash, then d" -- which
                // never matches a phone number. Every digit therefore got
                // masked and the client received +*********** instead of the
                // intended +*******0123. CustomResourceOwnerValidator.cs:98 is
                // the correct form and the two are meant to agree.
                PhoneNumber = sendPhoneNumber && user.PhoneNumber != null ? Regex.Replace(user.PhoneNumber, @"\d(?!\d{0,3}$)", "*") : null,
                    PrimaryMethod = primaryMethod,
                    SecondaryMethod = secondaryMethod,
                }
            };
            context.Result.IsError = false;
            context.Result.Subject = await TokenGenerationService.TransformTokenRequestAsync(context.Request, user, GrantType, new string[] { Config.MFA_GRANT_TYPE_SCOPE });
        }
    }
}
