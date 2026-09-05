using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Hosting;

namespace Streetwriters.Common.Accessors
{
    public class WampInitializer : IHostedService
    {
        private readonly WampServiceAccessor accessor;

        public WampInitializer(WampServiceAccessor accessor)
        {
            this.accessor = accessor;
        }

        public Task StartAsync(CancellationToken cancellationToken)
        {
            // ponytail: Fire-and-forget to avoid blocking host startup
            Task.Run(async () => await accessor.InitAsync());
            return Task.CompletedTask;
        }

        public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    }
}