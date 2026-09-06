using System.Threading.Tasks;
using AspNetCore.Identity.Mongo.Model;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Streetwriters.Common.Interfaces;
using Streetwriters.Common.Models;
using Streetwriters.Identity.Interfaces;
using Streetwriters.Identity.Services;

namespace Streetwriters.Identity.Controllers
{
    [ApiController]
    [Route("account")]
    public class SignupController : IdentityControllerBase
    {
        private IUserAccountService UserAccountService { get; set; }

        public SignupController(
            UserManager<User> userManager,
            ITemplatedEmailSender emailSender,
            SignInManager<User> signInManager,
            RoleManager<MongoRole> roleManager,
            IMFAService mfaService,
            IUserAccountService userAccountService) : base(userManager, emailSender, signInManager, roleManager, mfaService)
        {
            UserAccountService = userAccountService;
        }

        [HttpPost("signup")]
        public async Task<IActionResult> Signup([FromForm] string email, [FromForm] string password, [FromForm] string clientId)
        {
            var response = await UserAccountService.CreateUserAsync(clientId, email, password);
            
            // ponytail: if user already exists (created by EmailGrantValidator), return success with existing user
            if (response.Errors != null && response.Errors.Length > 0)
            {
                foreach (var error in response.Errors)
                {
                    if (error.Contains("Unable to create an account on this email"))
                    {
                        var existingUser = await UserManager.FindByEmailAsync(email.ToLowerInvariant());
                        if (existingUser != null)
                        {
                            return Ok(new SignupResponse
                            {
                                UserId = existingUser.Id.ToString(),
                                Scope = "notesnook.sync",
                                AccessTokenLifetime = 3600
                            });
                        }
                    }
                }
            }
            
            return Ok(response);
        }
    }
}
