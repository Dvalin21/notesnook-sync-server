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
using System.IO;
using System.Security.Claims;
using System.Threading.RateLimiting;
using AspNetCore.Identity.Mongo;
using IdentityServer4.MongoDB.Entities;
using IdentityServer4.MongoDB.Interfaces;
using IdentityServer4.MongoDB.Options;
using IdentityServer4.MongoDB.Stores;
using IdentityServer4.ResponseHandling;
using IdentityServer4.Services;
using IdentityServer4.Stores;
using IdentityServer4.Validation;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.IdentityModel.Tokens;
using MongoDB.Bson.Serialization;
using Quartz;
using Streetwriters.Common;
using Streetwriters.Common.Extensions;
using Streetwriters.Common.Interfaces;
using Streetwriters.Common.Messages;
using Streetwriters.Common.Models;
using Streetwriters.Common.Services;
using Streetwriters.Identity.Helpers;
using Streetwriters.Identity.Interfaces;
using Streetwriters.Identity.Jobs;
using Streetwriters.Identity.Services;
using Streetwriters.Identity.Validation;
using IdentityServer4.MongoDB.Configuration;

namespace Streetwriters.Identity
{
    public class Startup
    {

        public Startup(IConfiguration configuration, IWebHostEnvironment environment)
        {
            Configuration = configuration;
            WebHostEnvironment = environment;
        }

        private IConfiguration Configuration { get; }
        private IWebHostEnvironment WebHostEnvironment { get; }

        // This method gets called by the runtime. Use this method to add services to the container.
        public void ConfigureServices(IServiceCollection services)
        {
            var connectionString = Constants.MONGODB_CONNECTION_STRING;

            services.AddTransient<IEmailSender, EmailSender>();
            services.AddTransient<ITemplatedEmailSender, TemplatedEmailSender>();
            services.AddTransient<ISMSSender, SMSSender>();
            services.AddTransient<IPasswordHasher<User>, Argon2PasswordHasher<User>>();

            services.AddDefaultCors();

            //services.AddSingleton<IProfileService, UserService>();
            services.AddIdentityMongoDbProvider<User>(options =>
            {
                // Password settings.
                options.Password.RequireDigit = false;
                options.Password.RequireLowercase = false;
                options.Password.RequireNonAlphanumeric = false;
                options.Password.RequireUppercase = false;
                options.Password.RequiredLength = 8;
                options.Password.RequiredUniqueChars = 0;

                // Lockout settings.
                options.Lockout.DefaultLockoutTimeSpan = TimeSpan.FromMinutes(5);
                options.Lockout.MaxFailedAccessAttempts = 5;
                options.Lockout.AllowedForNewUsers = true;

                // User settings.
                //options.User.AllowedUserNameCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._";
                options.User.RequireUniqueEmail = true;

                options.Tokens.ChangeEmailTokenProvider = TokenOptions.DefaultPhoneProvider;
            }, (options) =>
            {
                options.RolesCollection = "roles";
                options.UsersCollection = "users";
                // options.MigrationCollection = "migration";
                options.ConnectionString = connectionString;
            }).AddDefaultTokenProviders();

            services.AddIdentityServer(
            options =>
            {
                options.Events.RaiseSuccessEvents = true;
                options.Events.RaiseFailureEvents = true;
                options.Events.RaiseErrorEvents = true;
                options.IssuerUri = Servers.IdentityServer.ToString();
            })
            .AddExtensionGrantValidator<EmailGrantValidator>()
            .AddExtensionGrantValidator<MFAGrantValidator>()
            .AddExtensionGrantValidator<MFAPasswordGrantValidator>()
            .AddConfigurationStore(options =>
            {
                options.ConnectionString = connectionString;
            })
            .AddAspNetIdentity<User>()
            .AddInMemoryClients(Config.Clients)
            .AddInMemoryApiResources(Config.ApiResources)
            .AddInMemoryApiScopes(Config.ApiScopes)
            .AddInMemoryIdentityResources(Config.IdentityResources)
            .AddKeyManagement()
            .AddFileSystemPersistence(Path.Combine(WebHostEnvironment.ContentRootPath, @"keystore"));

            services.Configure<MongoDBConfiguration>(options =>
            {
                options.ConnectionString = connectionString;
            });

            services.Configure<DataProtectionTokenProviderOptions>(options =>
            {
                options.TokenLifespan = TimeSpan.FromHours(2);
            });

            services.AddRateLimiter(options =>
            {
                options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
                options.AddSlidingWindowLimiter("strict", options =>
                {
                    options.PermitLimit = 30;
                    options.Window = TimeSpan.FromSeconds(60);
                    options.SegmentsPerWindow = 10;
                    options.QueueProcessingOrder = QueueProcessingOrder.OldestFirst;
                    options.QueueLimit = 0;
                });

                options.AddPolicy("super_strict", (context) =>
                {
                    var key = context.User?.FindFirstValue("sub") ?? "default";
                    return RateLimitPartition.GetSlidingWindowLimiter(key, (key) => new SlidingWindowRateLimiterOptions
                    {
                        PermitLimit = 6,
                        Window = TimeSpan.FromMinutes(1),
                        SegmentsPerWindow = 2,
                        QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
                        QueueLimit = 0,
                        AutoReplenishment = true
                    });
                });
            });

            services.AddAuthorizationBuilder().AddPolicy("mfa", policy =>
            {
                policy.AddAuthenticationSchemes("Bearer+jwt");
                policy.RequireClaim("scope", Config.MFA_GRANT_TYPE_SCOPE);
            });

            services.AddLocalApiAuthentication();
            services.AddAuthentication()
            .AddJwtBearer("Bearer+jwt", options =>
            {
                options.MapInboundClaims = false;
                // Deliberately the PUBLIC url, unlike the introspection clients
                // which use Servers.InternalURL(). This one validates JWT
                // signatures, and that requires the discovery document whose
                // ISSUER matches the one the tokens were minted with -- the
                // public URL. The jwks_uri in that document is absolute, so the
                // key fetch follows it off the network regardless.
                //
                // Consequence, stated plainly: the identity server must be able
                // to reach its own public hostname to validate a JWT. The data
                // path (Notesnook.API, SSE hub) no longer has that dependency.
                options.Authority = Servers.IdentityServer.ToString();
                options.RequireHttpsMetadata = false;
                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidTypes = ["at+jwt"],
                    ValidateAudience = false,
                    ValidateIssuerSigningKey = true,
                    ValidateIssuer = true,
                };
            });

            services.AddQuartzHostedService(q =>
            {
                q.WaitForJobsToComplete = true;
                q.AwaitApplicationStarted = true;
                q.StartDelay = TimeSpan.FromMinutes(1);
            });

            AddOperationalStore(services, new TokenCleanupOptions { Enable = true, Interval = 3600 * 12 });

            services.AddScoped<EmailAddressValidator>();
            services.AddScoped<IUserAccountService, UserAccountService>();
            services.AddTransient<IMFAService, MFAService>();
            services.AddControllers();
            services.AddTransient<IIntrospectionResponseGenerator, CustomIntrospectionResponseGenerator>();
            services.AddTransient<IProfileService, ProfileService>();
            services.AddTransient<ITokenGenerationService, TokenGenerationService>();
            services.AddTransient<ITokenResponseGenerator, TokenResponseHandler>();
            services.AddTransient<IRefreshTokenService, CustomRefreshTokenService>();
            services.AddTransient<IResourceOwnerPasswordValidator, CustomResourceOwnerValidator>();

            services.AddHealthChecks();
        }

        // This method gets called by the runtime. Use this method to configure the HTTP request pipeline.
        public void Configure(IApplicationBuilder app, IWebHostEnvironment env)
        {
            Console.WriteLine("[TRACE] Configure: Starting pipeline setup");

            // Was `env, "CF-Connecting-IP"`. CF-Connecting-IP is set by Cloudflare, and
            // this stack's TLS terminator is the operator's own proxy in front of
            // the internal Caddy -- which forwards it through untouched. So the
            // header name was chosen for a CDN this deployment does not sit
            // behind, while the value was being trusted as if it did.
            //
            // If the terminator is not Cloudflare, nothing overwrites that
            // header, so ANY caller can send CF-Connecting-IP: <anything> and
            // ASP.NET adopts it as the client address. That defeats anything
            // keyed on the remote IP -- the signup throttle on the notes API
            // reads exactly this value -- by rotating a header per request.
            //
            // The last parameter is the header name. `null` means X-Forwarded-For,
            // which is what X-ForwardedHeadersOptions defaults to and what both
            // Caddy and every mainstream TLS terminator in front of this stack
            // actually set. Pass a Cloudflare header name ONLY when the operator
            // has documented that the terminator is Cloudflare and overwrites it
            // -- Caddy's `trusted_proxies static private_ranges` does NOT do that
            // for a public CDN address.
            app.UseForwardedHeadersWithKnownProxies(env);
            Console.WriteLine("[TRACE] Configure: Forwarded headers configured");

            app.UseCors("notesnook");
            Console.WriteLine("[TRACE] Configure: CORS configured");

            app.UseVersion(Servers.IdentityServer);
            Console.WriteLine("[TRACE] Configure: Version endpoint configured");

            // WAMP MUST be before UseRouting so Map branch can intercept before endpoint routing
            // ponytail: WAMP disabled — incompatible with .NET 9, hangs middleware pipeline
            // Console.WriteLine("[TRACE] Configure: About to call UseWamp...");
            // ponytail: WAMP disabled — incompatible with .NET 9, breaks middleware pipeline
            // Full WAMP block removed

            app.UseRouting();
            Console.WriteLine("[TRACE] Configure: Routing configured");

            app.UseIdentityServer();
            Console.WriteLine("[TRACE] Configure: IdentityServer configured");

            app.UseRateLimiter();
            Console.WriteLine("[TRACE] Configure: Rate limiter configured");

            app.UseAuthentication();
            Console.WriteLine("[TRACE] Configure: Authentication configured");

            app.UseAuthorization();
            Console.WriteLine("[TRACE] Configure: Authorization configured");

            app.UseEndpoints(endpoints =>
            {
                endpoints.MapControllers();
                endpoints.MapHealthChecks("/health");
                Console.WriteLine("[TRACE] Configure: Endpoints mapped");
            });

            Console.WriteLine("[TRACE] Configure: Pipeline setup COMPLETE");
        }

        private static void AddOperationalStore(IServiceCollection services, TokenCleanupOptions? tokenCleanUpOptions = null)
        {
            BsonClassMap.RegisterClassMap<PersistedGrant>(cm =>
            {
                cm.AutoMap();
                cm.SetIgnoreExtraElements(true);
            });

            services.AddSingleton<IPersistedGrantDbContext, CustomPersistedGrantDbContext>();
            services.AddTransient<IPersistedGrantStore, PersistedGrantStore>();
            services.AddTransient<TokenCleanup>();

            services.AddQuartz(q =>
            {
                q.UseMicrosoftDependencyInjectionJobFactory();

                if (tokenCleanUpOptions?.Enable == true)
                {
                    var jobKey = new JobKey("TokenCleanupJob");
                    q.AddJob<TokenCleanupJob>(opts => opts.WithIdentity(jobKey));
                    q.AddTrigger(opts => opts
                        .ForJob(jobKey)
                        .WithIdentity("TokenCleanup-trigger")
                        .WithSimpleSchedule((s) => s.RepeatForever().WithIntervalInSeconds(tokenCleanUpOptions.Interval)));
                }
            });
        }
    }
}
