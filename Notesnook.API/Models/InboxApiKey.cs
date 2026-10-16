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

using System.Text.Json.Serialization;
using MongoDB.Bson;
using MongoDB.Bson.Serialization.Attributes;
using NanoidDotNet;
using Notesnook.API.Authorization;

namespace Notesnook.API.Models
{
    public class CreateInboxApiKeyRequest
    {
        [JsonPropertyName("name")]
        public required string Name { get; set; }

        [JsonPropertyName("expiryDate")]
        public long ExpiryDate { get; set; }
    }

    public class InboxApiKey
    {
        public InboxApiKey()
        {
            var random = Nanoid.Generate(size: 64);
            Key = "nn__" + random;
            KeyHash = InboxApiKeyHasher.Hash(Key);
        }

        // SHA-256 of Key, hex, lowercase. This is what authentication looks up.
        //
        // The plaintext Key used to be the lookup column, which meant the
        // database held a usable bearer credential for every user's inbox:
        // anyone who could read this collection -- a backup archive, a
        // misconfigured Mongo bind, a log of a query -- held live inbox keys.
        // A hash removes that entirely: the server compares a digest of the
        // presented key against a stored digest.
        //
        // Nanoid.Generate(size: 64) draws from the CSPRNG, so a plain SHA-256
        // is appropriate here (no password stretching needed): the input has
        // ~380 bits of entropy, which makes brute force irrelevant.
        [JsonPropertyName("keyHash")]
        public string KeyHash { get; set; } = string.Empty;

        // Plaintext, returned to the creating client ONCE and never again.
        // BsonIgnore is load-bearing: without it Mongo persists the plaintext
        // key alongside the hash and the whole point is lost. The client still
        // receives it over the create response because that path serializes to
        // JSON, not BSON.
        [JsonPropertyName("key")]
        [BsonIgnore]
        public string Key { get; set; } = string.Empty;

        [BsonId]
        [BsonIgnoreIfDefault]
        [BsonRepresentation(BsonType.ObjectId)]
        [JsonIgnore]
        [MessagePack.IgnoreMember]
        public string Id { get; set; } = string.Empty;

        [JsonPropertyName("userId")]
        public required string UserId { get; set; }

        [JsonPropertyName("name")]
        public required string Name { get; set; }

        [JsonPropertyName("dateCreated")]
        public long DateCreated { get; set; }

        [JsonPropertyName("expiryDate")]
        public long ExpiryDate { get; set; }

        [JsonPropertyName("lastUsedAt")]
        public long LastUsedAt { get; set; }
    }
}
