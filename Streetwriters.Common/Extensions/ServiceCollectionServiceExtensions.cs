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
using System.Linq;
using Microsoft.Extensions.DependencyInjection;
using Streetwriters.Common.Accessors;
using Streetwriters.Data.DbContexts;
using Streetwriters.Data.Repositories;

namespace Streetwriters.Common.Extensions
{
    public static class ServiceCollectionServiceExtensions
    {
        public static IServiceCollection AddWampServiceAccessor(this IServiceCollection services, Server server)
        {
            var accessor = new WampServiceAccessor(server);
            services.AddSingleton<WampServiceAccessor>((_) => accessor);
            services.AddHostedService(provider => new WampInitializer(provider.GetRequiredService<WampServiceAccessor>()));
            return services;
        }

        public static IServiceCollection AddRepository<T>(this IServiceCollection services, string collectionName, string database) where T : class
        {
            services.AddSingleton((provider) => MongoDbContext.GetMongoCollection<T>(provider.GetRequiredService<MongoDB.Driver.IMongoClient>(), database, collectionName));
            services.AddScoped<Repository<T>>();
            return services;
        }

        public static IServiceCollection AddDefaultCors(this IServiceCollection services)
        {
            var origins = Constants.NOTESNOOK_CORS_ORIGINS;

            if (origins.Length <= 0)
            {
                // Refuse to start rather than fall back to AllowAnyOrigin().
                //
                // The old code called b.AllowAnyOrigin() here, so a blank or
                // mistyped NOTESNOOK_CORS_ORIGINS turned into "every website on
                // the internet may call this API". That is silent and it is the
                // wrong default for a service holding end-to-end encrypted
                // account data behind a bearer token. .env.example warns about
                // it in prose; prose is not a control.
                //
                // There is no legitimate self-hosted configuration that needs a
                // wildcard here: the web client's own origin is what this must
                // allow, and that is required by the compose `validate` service.
                throw new InvalidOperationException(
                    "NOTESNOOK_CORS_ORIGINS is empty. Refusing to start with a "
                    + "permissive CORS policy (AllowAnyOrigin). Set it to your web "
                    + "client's origin, e.g. https://app.example.com -- see "
                    + ".env.example. The previous behaviour silently allowed every "
                    + "origin."
                );
            }

            if (origins.Contains("*"))
            {
                throw new InvalidOperationException(
                    "NOTESNOOK_CORS_ORIGINS contains '*'. Refusing to start: a "
                    + "wildcard origin on the notes API exposes account data to any "
                    + "site the holder of a session token visits."
                );
            }

            services.AddCors(options =>
            {
                options.AddPolicy("notesnook", (b) =>
                {
                    b.WithOrigins(origins);

                    b.AllowAnyMethod()
                    .AllowAnyHeader()
                    .WithExposedHeaders(["X-Object-Size", "Content-Length"]);
                });
            });
            return services;
        }
    }
}
