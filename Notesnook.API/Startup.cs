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
using System.Diagnostics;
using System.IdentityModel.Tokens.Jwt;
using System.IO.Compression;
using System.Security.Claims;
using System.Text;
using System.Text.Encodings.Web;
using System.Threading.RateLimiting;
using System.Threading.Tasks;
using Amazon.Runtime;
using StackExchange.Redis;
using IdentityModel.AspNetCore.OAuth2Introspection;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Connections;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.ResponseCompression;
using Microsoft.Extensions.Caching.Distributed;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using MongoDB.Bson.Serialization;
using Notesnook.API.Accessors;
using Notesnook.API.Authorization;
using Notesnook.API.Extensions;
using Notesnook.API.Hubs;
using Notesnook.API.Interfaces;
using Notesnook.API.Jobs;
using Notesnook.API.Models;
using Notesnook.API.Repositories;
using Notesnook.API.Services;
// ponytail: OpenTelemetry commented out for debugging
// using OpenTelemetry.Metrics;
// using OpenTelemetry.Resources;
// using Quartz; // ponytail: Quartz commented out
using Streetwriters.Common;
using Streetwriters.Common.Accessors;
using Streetwriters.Common.Extensions;
using Streetwriters.Common.Interfaces;
using Streetwriters.Common.Messages;
using Streetwriters.Common.Models;
using Streetwriters.Common.Services;
using Streetwriters.Data;
using Streetwriters.Data.DbContexts;
using Streetwriters.Data.Interfaces;
using Streetwriters.Data.Repositories;

namespace Notesnook.API
{
    public class Startup
    {
        public Startup(IConfiguration configuration)
        {
            Configuration = configuration;
        }

        public IConfiguration Configuration { get; }

        // This method gets called by the runtime. Use this method to add services to the container.
        public void ConfigureServices(IServiceCollection services)
        {
            Trace("ConfigureServices: START");

            Trace("ConfigureServices: MongoDbContext");
            services.AddSingleton(MongoDbContext.CreateMongoDbClient(new DbSettings
            {
                ConnectionString = Constants.MONGODB_CONNECTION_STRING,
                DatabaseName = Constants.MONGODB_DATABASE_NAME
            }));

            Trace("ConfigureServices: HttpContextAccessor");
            services.TryAddSingleton<IHttpContextAccessor, HttpContextAccessor>();

            JwtSecurityTokenHandler.DefaultMapInboundClaims = false;
            JwtSecurityTokenHandler.DefaultInboundClaimTypeMap.Clear();

            Trace("ConfigureServices: DefaultCors");
            services.AddDefaultCors();

            Trace("ConfigureServices: DistributedMemoryCache");
            services.AddDistributedMemoryCache(delegate (MemoryDistributedCacheOptions cacheOptions)
            {
                cacheOptions.SizeLimit = 262144000L;
            });

            Trace("ConfigureServices: RateLimiter");
            // The sync server had NO rate limiter at all. Streetwriters.Identity
            // registers its own, but this is a separate service with a separate
            // DI container, so [EnableRateLimiting] on an action here would throw
            // at startup if the policy were not registered here too.
            //
            // Signup is the reason: POST /users is [AllowAnonymous] and
            // unthrottled, and UserAccountService only validates that an email
            // address is well-FORMED, never that the caller owns it. Measured on a
            // live instance: 5 accounts in 1.58s, each sending a real message to
            // an attacker-chosen address. That is an email relay, and it is the
            // one way an anonymous caller can make this server talk to the world.
            //
            // Keyed on the client IP. That is only meaningful because
            // UseForwardedHeadersWithKnownProxies (Startup.cs, later) is
            // configured AND KNOWN_PROXIES names Caddy -- without that every
            // request appears to come from the proxy and this becomes one global
            // bucket, which is worse than no limit because it looks configured.
            services.AddRateLimiter(options =>
            {
                options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
                options.AddPolicy("signup", context =>
                {
                    var key = context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
                    return RateLimitPartition.GetSlidingWindowLimiter(key, _ =>
                        new SlidingWindowRateLimiterOptions
                        {
                            // A self-hosted instance is usually a household behind
                            // one NAT address. 5 per 10 minutes lets a family
                            // register several people while stopping a relay, which
                            // needs volume to be worth anything.
                            PermitLimit = 5,
                            Window = TimeSpan.FromMinutes(10),
                            SegmentsPerWindow = 10,
                            QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
                            QueueLimit = 0,
                            AutoReplenishment = true
                        });
                });
            });

            Trace("ConfigureServices: Authorization");
            services.AddAuthorization(options =>
            {
                options.AddPolicy("Notesnook", policy =>
                {
                    policy.AuthenticationSchemes.Add("introspection");
                    policy.RequireAuthenticatedUser();
                    policy.Requirements.Add(new NotesnookUserRequirement());
                });
                options.AddPolicy("Sync", policy =>
                {
                    policy.AuthenticationSchemes.Add("introspection");
                    policy.RequireAuthenticatedUser();
                    policy.Requirements.Add(new SyncRequirement());
                });

                options.AddPolicy(InboxApiKeyAuthenticationDefaults.AuthenticationScheme, policy =>
                {
                    policy.AuthenticationSchemes.Add(InboxApiKeyAuthenticationDefaults.AuthenticationScheme);
                    policy.RequireAuthenticatedUser();
                });

                options.DefaultPolicy = options.GetPolicy("Notesnook") ?? throw new Exception("Notesnook policy not found");
            }).AddSingleton<IAuthorizationMiddlewareResultHandler, AuthorizationResultTransformer>();

            Trace("ConfigureServices: Authentication");
            services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddOAuth2Introspection("introspection", options =>
            {
                options.Authority = Servers.IdentityServer.ToString();
                options.ClientSecret = Constants.NOTESNOOK_API_SECRET;
                options.ClientId = "notesnook";
                options.DiscoveryPolicy.RequireHttps = false;
                options.TokenRetriever = new Func<HttpRequest, string>(req =>
                {
                    var fromHeader = TokenRetrieval.FromAuthorizationHeader();
                    var fromQuery = TokenRetrieval.FromQueryString();
                    return fromHeader(req) ?? fromQuery(req);
                });

                options.Events.OnTokenValidated = (context) =>
                {
                    if (long.TryParse(context.Principal?.FindFirst("exp")?.Value, out long expiryTime))
                    {
                        context.Properties.ExpiresUtc = DateTimeOffset.FromUnixTimeSeconds(expiryTime);
                    }
                    context.Properties.AllowRefresh = true;
                    context.Properties.IsPersistent = true;
                    context.HttpContext.User = context.Principal ?? throw new Exception("No principal found in token.");
                    return Task.CompletedTask;
                };
                options.CacheKeyGenerator = (options, token) => (token + ":" + "reference_token").Sha256();
                options.SaveToken = true;
                options.EnableCaching = true;
                options.CacheDuration = TimeSpan.FromMinutes(30);
            })
            .AddScheme<InboxApiKeyAuthenticationSchemeOptions, InboxApiKeyAuthenticationHandler>(
                InboxApiKeyAuthenticationDefaults.AuthenticationScheme,
                options => { }
            );

            Trace("ConfigureServices: BsonClassMap");
            if (!BsonClassMap.IsClassMapRegistered(typeof(UserSettings)))
                BsonClassMap.RegisterClassMap<UserSettings>();

            if (!BsonClassMap.IsClassMapRegistered(typeof(EncryptedData)))
                BsonClassMap.RegisterClassMap<EncryptedData>();

            if (!BsonClassMap.IsClassMapRegistered(typeof(CallToAction)))
                BsonClassMap.RegisterClassMap<CallToAction>();

            if (!BsonClassMap.IsClassMapRegistered(typeof(SyncDevice)))
                BsonClassMap.RegisterClassMap<SyncDevice>();

            Trace("ConfigureServices: DbContext/UnitOfWork");
            services.AddScoped<IDbContext, MongoDbContext>();
            services.AddScoped<IUnitOfWork, UnitOfWork>();

            Trace("ConfigureServices: Repositories");
            var dbName = Constants.MONGODB_DATABASE_NAME;
            services.AddRepository<UserSettings>("user_settings", dbName)
                    .AddRepository<Monograph>("monographs", dbName)
                    .AddRepository<Announcement>("announcements", dbName)
                    .AddRepository<DeviceIdsChunk>(Collections.DeviceIdsChunksKey, dbName)
                    .AddRepository<SyncDevice>(Collections.SyncDevicesKey, dbName)
                    .AddRepository<InboxApiKey>(Collections.InboxApiKeysKey, dbName)
                    .AddRepository<InboxSyncItem>(Collections.InboxItemsKey, dbName);

            Trace("ConfigureServices: MongoCollections");
            services.AddMongoCollection(Collections.SettingsKey)
                    .AddMongoCollection(Collections.AttachmentsKey)
                    .AddMongoCollection(Collections.ContentKey)
                    .AddMongoCollection(Collections.NotesKey)
                    .AddMongoCollection(Collections.NotebooksKey)
                    .AddMongoCollection(Collections.RelationsKey)
                    .AddMongoCollection(Collections.RemindersKey)
                    .AddMongoCollection(Collections.LegacySettingsKey)
                    .AddMongoCollection(Collections.ShortcutsKey)
                    .AddMongoCollection(Collections.TagsKey)
                    .AddMongoCollection(Collections.ColorsKey)
                    .AddMongoCollection(Collections.VaultsKey)
                    .AddMongoCollection(Collections.InboxItemsKey)
                    .AddMongoCollection(Collections.InboxApiKeysKey)
                    .AddMongoCollection(Collections.InboxItemsHistoryKey);

            Trace("ConfigureServices: Services");
            services.AddScoped<ISyncItemsRepositoryAccessor, SyncItemsRepositoryAccessor>();
            services.AddScoped<SyncDeviceService>();
            services.AddScoped<IUserService, UserService>();

            services.AddScoped<IS3Service, S3Service>();
            services.AddScoped<IURLAnalyzer, URLAnalyzer>();

            // ponytail: HTTP client for Identity Server (WAMP replacement)
            services.AddHttpClient("IdentityServer", client =>
            {
                client.BaseAddress = new Uri($"http://{Constants.IDENTITY_SERVER_HOST}:{Constants.IDENTITY_SERVER_PORT}/");
                client.DefaultRequestHeaders.Add("Accept", "application/json");
            });
            services.AddScoped<Streetwriters.Common.Interfaces.IUserAccountService, Services.UserAccountService>();

            // ponytail: WampServiceAccessor registered as singleton only (NOT hosted service)
            // The hosted service StartAsync blocks on WAMP RPC call which hangs indefinitely
            services.AddSingleton<WampServiceAccessor>((provider) => new WampServiceAccessor(Servers.NotesnookAPI));
            services.AddScoped<IURLAnalyzer, URLAnalyzer>();

            Trace("ConfigureServices: Controllers");
            services.AddControllers();

            Trace("ConfigureServices: HealthChecks");
            services.AddHealthChecks();

            Trace("ConfigureServices: SignalR");
            var signalR = services.AddSignalR((hub) =>
            {
                hub.MaximumReceiveMessageSize = 100 * 1024 * 1024;
                hub.KeepAliveInterval = TimeSpan.FromSeconds(15);
                hub.ClientTimeoutInterval = TimeSpan.FromMinutes(10);
                hub.EnableDetailedErrors = true;
            }).AddMessagePackProtocol().AddJsonProtocol();

            Trace("ConfigureServices: SignalR Redis check");
            if (!string.IsNullOrEmpty(Constants.SIGNALR_REDIS_CONNECTION_STRING))
            {
                Trace("ConfigureServices: SignalR Redis - SKIPPED (no connection string)");
            }

            Trace("ConfigureServices: ResponseCompression");
            services.AddResponseCompression(options =>
            {
                options.EnableForHttps = true;
                options.Providers.Add<BrotliCompressionProvider>();
                options.Providers.Add<GzipCompressionProvider>();
            });

            services.Configure<BrotliCompressionProviderOptions>(options =>
            {
                options.Level = CompressionLevel.Fastest;
            });
            services.Configure<GzipCompressionProviderOptions>(options =>
            {
                options.Level = CompressionLevel.Fastest;
            });

            // ponytail: OpenTelemetry commented out for debugging
            // Trace("ConfigureServices: OpenTelemetry");
            // services.AddOpenTelemetry()
            //         .ConfigureResource(resource => resource
            //             .AddService(serviceName: "Notesnook.API"))
            //         .WithMetrics((builder) => builder
            //                 .AddMeter("Notesnook.API.Metrics.Sync")
            //                 .AddPrometheusExporter());


            // ponytail: Quartz commented out for debugging (AwaitApplicationStarted = true causes deadlock)
            // Trace("ConfigureServices: Quartz");
            // services.AddQuartzHostedService(q =>
            // {
            //     q.WaitForJobsToComplete = false;
            //     q.AwaitApplicationStarted = true;
            //     q.StartDelay = TimeSpan.FromMinutes(1);
            // }).AddQuartz(q =>
            // {
            //     q.UseMicrosoftDependencyInjectionJobFactory();
            //     var jobKey = new JobKey("DeviceCleanupJob");
            //     q.AddJob<DeviceCleanupJob>(opts => opts.WithIdentity(jobKey));
            //     q.AddTrigger(opts => opts
            //         .ForJob(jobKey)
            //         .WithIdentity("DeviceCleanup-trigger")
            //         .WithCronSchedule("0 0 0 1 * ? *"));
            // });

            Trace("ConfigureServices: END");
        }

        // This method gets called by the runtime. Use this method to configure the HTTP request pipeline.
        public void Configure(IApplicationBuilder app, IWebHostEnvironment env)
        {
            Trace("Configure: START");

              app.UseForwardedHeadersWithKnownProxies(env);


            // ponytail: OpenTelemetry commented out for debugging
            // app.UseOpenTelemetryPrometheusScrapingEndpoint((context) => context.Request.Path == "/metrics" && context.Connection.LocalPort == 5067);

            Trace("Configure: ResponseCompression");
            app.UseResponseCompression();

            Trace("Configure: WebSockets");
            app.UseWebSockets(new Microsoft.AspNetCore.Builder.WebSocketOptions
            {
                KeepAliveInterval = TimeSpan.FromSeconds(30),
                KeepAliveTimeout = TimeSpan.FromSeconds(60),
            });

            Trace("Configure: Cors");
            app.UseCors("notesnook");

            Trace("Configure: Version");
            app.UseVersion(Servers.NotesnookAPI);

            Trace("Configure: WAMP");

            Trace("Configure: Routing");
            app.UseRouting();

            // Must come AFTER UseRouting, not before. The rate limiting middleware
            // reads [EnableRateLimiting] from ENDPOINT metadata, which does not
            // exist until routing has run. Two ways this failed on a live build,
            // both silently allowing every request:
            //   1. AddRateLimiter without UseRateLimiter -- policy defined, never
            //      enforced. 8 signups against a limit of 5 -> 8x HTTP 200, 8 emails.
            //   2. UseRateLimiter placed before UseRouting -- middleware runs, but
            //      finds no endpoint metadata, so the attribute is invisible.
            // Streetwriters.Identity/Startup.cs has had the correct order all along.
            app.UseRateLimiter();

            Trace("Configure: Authentication");
            app.UseAuthentication();

            Trace("Configure: Authorization");
            app.UseAuthorization();

            Trace("Configure: Endpoints");
            app.UseEndpoints(endpoints =>
            {
                endpoints.MapControllers();
                endpoints.MapHealthChecks("/health");
                endpoints.MapHub<SyncV2Hub>("/hubs/sync/v2", options =>
                {
                    options.CloseOnAuthenticationExpiration = false;
                    options.Transports = HttpTransportType.WebSockets;
                });
            });

            Trace("Configure: END");
        }

        private static void Trace(string message)
        {
            Console.WriteLine($"[TRACE] {DateTime.UtcNow:O} {message}");
            Debug.WriteLine(message);
        }
    }

    public static class ServiceCollectionMongoCollectionExtensions
    {
        public static IServiceCollection AddMongoCollection(this IServiceCollection services, string collectionName, string database = "notesnook")
        {
            services.AddKeyedSingleton(collectionName, (provider, key) => MongoDbContext.GetMongoCollection<SyncItem>(provider.GetRequiredService<MongoDB.Driver.IMongoClient>(), database, collectionName));
            return services;
        }
    }
}
