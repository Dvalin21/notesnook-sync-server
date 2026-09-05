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
using System.Threading;
using System.Threading.Tasks;
using Streetwriters.Common.Interfaces;

namespace Streetwriters.Common.Accessors
{
    public class WampServiceAccessor(Server server)
    {
        private IUserAccountService? userAccountService;
        private IUserSubscriptionService? userSubscriptionService;
        private TaskCompletionSource<bool> initTcs = new();
        private bool initialized = false;

        public IUserAccountService UserAccountService
        {
            get
            {
                if (userAccountService == null)
                {
                    Console.WriteLine($"[WAMP] UserAccountService accessed before init, waiting 30s (server={server.Hostname})");
                    initTcs.Task.Wait(TimeSpan.FromSeconds(30));
                }
                if (userAccountService == null)
                    Console.WriteLine($"[WAMP] UserAccountService STILL NULL after 30s wait (server={server.Hostname})");
                else
                    Console.WriteLine($"[WAMP] UserAccountService returned successfully (server={server.Hostname})");
                return userAccountService ?? throw new InvalidOperationException("WAMP service not initialized");
            }
        }

        public IUserSubscriptionService? UserSubscriptionService
        {
            get
            {
                if (!initialized)
                {
                    initTcs.Task.Wait(TimeSpan.FromSeconds(30));
                }
                return userSubscriptionService;
            }
        }

        public async Task InitAsync()
        {
            try
            {
                Console.WriteLine($"[WAMP] InitAsync: Connecting to IdentityServer WAMP at {WampServers.IdentityServer.Address}...");
                userAccountService = await WampServers.IdentityServer.GetServiceAsync<IUserAccountService>();
                Console.WriteLine($"[WAMP] InitAsync: Got IUserAccountService={userAccountService != null}");

                if (!Constants.IS_SELF_HOSTED && server != Servers.SubscriptionServer)
                {
                    Console.WriteLine($"[WAMP] InitAsync: Connecting to SubscriptionServer WAMP...");
                    userSubscriptionService = await WampServers.SubscriptionServer.GetServiceAsync<IUserSubscriptionService>();
                    Console.WriteLine($"[WAMP] InitAsync: Got IUserSubscriptionService={userSubscriptionService != null}");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[WAMP] InitAsync FAILED: {ex.GetType().Name}: {ex.Message}");
            }
            finally
            {
                initialized = true;
                initTcs.SetResult(true);
            }
        }
    }
}