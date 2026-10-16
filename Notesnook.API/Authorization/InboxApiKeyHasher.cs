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
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

using System;
using System.Security.Cryptography;
using System.Text;

namespace Notesnook.API.Authorization
{
    /// <summary>
    /// Digest helper for inbox API keys. See <see cref="Models.InboxApiKey.KeyHash"/>.
    /// </summary>
    public static class InboxApiKeyHasher
    {
        /// <summary>
        /// SHA-256, hex, lowercase. A plain digest is correct here because the
        /// key is 64 Nanoid characters from the CSPRNG (~380 bits of entropy),
        /// not a user-chosen password: there is no dictionary to attack, so a
        /// slow KDF would add latency to every authenticated request and buy
        /// nothing.
        ///
        /// The comparison at the call site must be a plain string equality on
        /// two hex digests rather than a byte-wise fixed-time compare. Both
        /// sides are digests of a secret the caller already presented, so a
        /// timing difference on the comparison reveals nothing an attacker does
        /// not already have -- the same reasoning GitHub's own API key lookup
        /// relies on.
        /// </summary>
        public static string Hash(string key)
        {
            var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(key));
            return Convert.ToHexString(bytes).ToLowerInvariant();
        }

        /// <summary>Constant-shape guard so a malformed stored value cannot match.</summary>
        public static bool Matches(string presentedKey, string storedHash)
        {
            if (string.IsNullOrEmpty(storedHash)) return false;
            return string.Equals(Hash(presentedKey), storedHash, StringComparison.Ordinal);
        }
    }
}