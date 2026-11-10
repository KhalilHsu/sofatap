using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using SofaTap;

internal static class ControllerTakeoverChecks
{
    // Real TLS + WebSocket server in dry-run mode. A live controller keeps the
    // single-controller slot; a silent (dead-route) controller is replaced.
    internal static async Task Run(Action<bool, string> check)
    {
        var directory = Path.Combine(Path.GetTempPath(), "sofatap-takeover-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var credentials = Credentials.LoadOrCreate(directory);
            var server = new ReceiverServer(new(true, directory, 0), credentials, new DryRunInput());
            await using var app = server.Build();
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(40));
            await app.StartAsync(deadline.Token);
            try
            {
                var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single();
                var uri = new UriBuilder("wss", "127.0.0.1", new Uri(address).Port, "/control").Uri;
                var pin = SHA256.HashData(credentials.Certificate.RawData);
                ClientWebSocket Client()
                {
                    var socket = new ClientWebSocket();
                    socket.Options.Proxy = null;
                    socket.Options.RemoteCertificateValidationCallback = (_, certificate, _, _) =>
                        certificate is not null && CryptographicOperations.FixedTimeEquals(SHA256.HashData(certificate.GetRawCertData()), pin);
                    socket.Options.SetRequestHeader("Authorization", "Bearer " + credentials.Token);
                    return socket;
                }
                async Task<bool> Connects(ClientWebSocket socket)
                {
                    try { await socket.ConnectAsync(uri, deadline.Token); return true; }
                    catch (WebSocketException) { return false; }
                }
                async Task Ping(ClientWebSocket socket)
                {
                    var bytes = Encoding.UTF8.GetBytes($"{{\"type\":\"ping\",\"id\":\"{Guid.NewGuid():D}\"}}");
                    await socket.SendAsync(bytes, WebSocketMessageType.Text, true, deadline.Token);
                    var buffer = new byte[70000];
                    await socket.ReceiveAsync(buffer, deadline.Token);
                }
                using var first = Client();
                check(await Connects(first), "takeover fixture: first controller connects");
                await first.ReceiveAsync(new byte[70000], deadline.Token); // hello
                using (var second = Client())
                    check(!await Connects(second), "a second controller is still denied while the first is live");
                // Keep the first controller pinging like a phone for longer than the stale budget.
                var until = DateTime.UtcNow + ReceiverServer.StaleControllerAfter + TimeSpan.FromSeconds(1);
                while (DateTime.UtcNow < until) { await Ping(first); await Task.Delay(500, deadline.Token); }
                using (var third = Client())
                    check(!await Connects(third), "a pinging controller is never replaced");
                // Now go silent, as a stalled peer-to-peer route does.
                await Task.Delay(ReceiverServer.StaleControllerAfter + TimeSpan.FromMilliseconds(700), deadline.Token);
                using var replacement = Client();
                check(await Connects(replacement), "a silent stale controller is replaced by a new authenticated connection");
                await replacement.ReceiveAsync(new byte[70000], deadline.Token);
                await Ping(replacement);
                check(replacement.State == WebSocketState.Open, "replacement controller is fully usable");
                var closed = false;
                try { await first.ReceiveAsync(new byte[70000], deadline.Token); closed = first.State != WebSocketState.Open; }
                catch (WebSocketException) { closed = true; }
                check(closed, "the replaced controller is disconnected");
                using (var unauthorized = new ClientWebSocket())
                {
                    unauthorized.Options.RemoteCertificateValidationCallback = (_, _, _, _) => true;
                    unauthorized.Options.SetRequestHeader("Authorization", "Bearer wrong");
                    var ok = true; try { await unauthorized.ConnectAsync(uri, deadline.Token); } catch (WebSocketException) { ok = false; }
                    check(!ok, "takeover still requires the pairing token");
                }
            }
            finally { await app.StopAsync(CancellationToken.None); }
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
}
