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

using AspNetCore.Identity.Mongo.Model;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Claims;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using IdentityServer4;
using IdentityServer4.Models;
using IdentityServer4.Stores;
using IdentityServer4.Validation;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Logging;
using Streetwriters.Common.Enums;
using Streetwriters.Common.Models;
using Streetwriters.Identity.Interfaces;
using Streetwriters.Identity.Models;
using static IdentityModel.OidcConstants;

namespace Streetwriters.Identity.Validation
{
    public class EmailGrantValidator : IExtensionGrantValidator
    {
        private UserManager<User> UserManager { get; set; }
        private RoleManager<MongoRole> RoleManager { get; set; }
        private SignInManager<User> SignInManager { get; set; }
        private IMFAService MFAService { get; set; }
        private ITokenGenerationService TokenGenerationService { get; set; }
        private JwtRequestValidator JWTRequestValidator { get; set; }
        private IResourceStore ResourceStore { get; set; }
        private IUserClaimsPrincipalFactory<User> PrincipalFactory { get; set; }
        private ILogger<EmailGrantValidator> _logger;

        public EmailGrantValidator(UserManager<User> userManager, RoleManager<MongoRole> roleManager, SignInManager<User> signInManager, IMFAService mfaService, ITokenGenerationService tokenGenerationService,
        IResourceStore resourceStore, IUserClaimsPrincipalFactory<User> principalFactory, ILogger<EmailGrantValidator> logger)
        {
            UserManager = userManager;
            RoleManager = roleManager;
            SignInManager = signInManager;
            MFAService = mfaService;
            TokenGenerationService = tokenGenerationService;
            ResourceStore = resourceStore;
            PrincipalFactory = principalFactory;
            _logger = logger;
        }

        public string GrantType => Config.EMAIL_GRANT_TYPE;


        public async Task ValidateAsync(ExtensionGrantValidationContext context)
        {
            var email = context.Request.Raw["email"];
            var clientId = context.Request.ClientId;
            var existingUser = await UserManager.FindRegisteredUserAsync(email, clientId);
            _logger.LogDebug("[EmailGrantValidator] FindRegisteredUserAsync email={Email} clientId={ClientId} existingUser={Exists}", email, clientId, existingUser != null ? "FOUND" : "NOT_FOUND");
            var user = existingUser ?? new User
            {
                Id = MongoDB.Bson.ObjectId.GenerateNewId(),
                Email = email,
                UserName = email,
                NormalizedEmail = email,
                NormalizedUserName = email,
                EmailConfirmed = false,
                SecurityStamp = ""
            };

            // Save new user to database so MFA grant can find them
            if (existingUser == null)
            {
                // Ensure role exists before creating user
                if (await RoleManager.FindByNameAsync(clientId) == null)
                {
                    await RoleManager.CreateAsync(new MongoRole(clientId));
                }

                var createResult = await UserManager.CreateAsync(user);
                if (!createResult.Succeeded)
                {
                    Console.WriteLine($"[EmailGrantValidator] CreateAsync FAILED - returning invalid_grant. Errors: {string.Join(", ", createResult.Errors.Select(e => e.Description))}");
                    context.Result = new GrantValidationResult(TokenRequestErrors.InvalidGrant);
                    return;
                }
                await UserManager.AddToRoleAsync(user, clientId);
            }

            var isMultiFactor = await UserManager.GetTwoFactorEnabledAsync(user);

            var primaryMethod = isMultiFactor ? MFAService.GetPrimaryMethod(user) : MFAMethods.Email;
            var secondaryMethod = MFAService.GetSecondaryMethod(user);
            var sendPhoneNumber = primaryMethod == MFAMethods.SMS || secondaryMethod == MFAMethods.SMS;

            context.Result.CustomResponse = new Dictionary<string, object>
            {
                ["additional_data"] = new MFARequiredResponse
                {
                    PhoneNumber = sendPhoneNumber && user.PhoneNumber != null ? Regex.Replace(user.PhoneNumber, @"\d(?!\\d{0,3}$)", "*") : null,
                    PrimaryMethod = primaryMethod,
                    SecondaryMethod = secondaryMethod,
                }
            };
            context.Result.IsError = false;
            context.Result.Subject = await TokenGenerationService.TransformTokenRequestAsync(context.Request, user, GrantType, new string[] { Config.MFA_GRANT_TYPE_SCOPE });
        }
    }
}