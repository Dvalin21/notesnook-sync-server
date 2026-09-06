using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using Streetwriters.Common.Interfaces;
using Streetwriters.Common.Models;

namespace Notesnook.API.Services
{
    public class UserAccountService : IUserAccountService
    {
        private readonly IHttpClientFactory _httpClientFactory;
        private readonly IHttpContextAccessor _httpContextAccessor;
        private readonly ILogger<UserAccountService> _logger;

        public UserAccountService(IHttpClientFactory httpClientFactory, IHttpContextAccessor httpContextAccessor, ILogger<UserAccountService> logger)
        {
            _httpClientFactory = httpClientFactory;
            _httpContextAccessor = httpContextAccessor;
            _logger = logger;
        }

        // ponytail: identity's /account endpoints authorize the CALLER — a
        // server-to-server HttpClient has no ambient auth, so forward the
        // incoming bearer token or identity answers 401.
        private void ForwardCallerAuth(HttpRequestMessage request)
        {
            var auth = _httpContextAccessor.HttpContext?.Request.Headers.Authorization.ToString();
            if (!string.IsNullOrEmpty(auth))
                request.Headers.TryAddWithoutValidation("Authorization", auth);
        }

        public async Task<SignupResponse> CreateUserAsync(string clientId, string email, string password, string userAgent)
        {
            var client = _httpClientFactory.CreateClient("IdentityServer");
            var response = await client.PostAsync("/account/signup", new FormUrlEncodedContent(new[]
            {
                new KeyValuePair<string, string>("email", email),
                new KeyValuePair<string, string>("password", password),
                new KeyValuePair<string, string>("clientId", clientId)
            }));
            var content = await response.Content.ReadAsStringAsync();
            response.EnsureSuccessStatusCode();
            return JsonSerializer.Deserialize<SignupResponse>(content, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }

        public async Task<UserModel> GetUserAsync(string clientId, string userId)
        {
            var client = _httpClientFactory.CreateClient("IdentityServer");
            var request = new HttpRequestMessage(HttpMethod.Get, $"/account?clientId={clientId}&userId={userId}");
            ForwardCallerAuth(request);
            var response = await client.SendAsync(request);
            var content = await response.Content.ReadAsStringAsync();
            response.EnsureSuccessStatusCode();
            return JsonSerializer.Deserialize<UserModel>(content, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }

        public async Task DeleteUserAsync(string clientId, string userId, string password)
        {
            var client = _httpClientFactory.CreateClient("IdentityServer");
            var request = new HttpRequestMessage(HttpMethod.Delete, $"/account?clientId={clientId}&userId={userId}&password={password}");
            ForwardCallerAuth(request);
            var response = await client.SendAsync(request);
        }

        public Task<bool> ChangePasswordAsync(string userId, string oldPassword, string newPassword) => throw new NotImplementedException();
        public Task<bool> ResetPasswordAsync(string userId, string newPassword) => throw new NotImplementedException();
        public Task<bool> ClearSessionsAsync(string userId, string clientId, bool all, string jti, string refreshToken) => throw new NotImplementedException();
    }
}
