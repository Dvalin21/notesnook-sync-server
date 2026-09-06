using System.Threading.Tasks;
using Streetwriters.Common.Models;

namespace Streetwriters.Common.Interfaces
{
    public interface IUserAccountService
    {
        Task<UserModel?> GetUserAsync(string clientId, string userId);
        Task DeleteUserAsync(string clientId, string userId, string password);
        Task<bool> ChangePasswordAsync(string userId, string oldPassword, string newPassword);
        Task<bool> ResetPasswordAsync(string userId, string newPassword);
        Task<bool> ClearSessionsAsync(string userId, string clientId, bool all, string jti, string? refreshToken);
        Task<SignupResponse> CreateUserAsync(string clientId, string email, string password, string? userAgent = null);
    }
}