using System.Net;
using System.Text;
using Feed;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.DependencyInjection;

// Kestrel hosts the server: our io_uring transport (Loop.cs) replaces its socket transport.
string sqlitePath = Environment.GetEnvironmentVariable("SQLITE_PATH") ?? throw new InvalidOperationException("SQLITE_PATH is not set");
string secret = Environment.GetEnvironmentVariable("JWT_SECRET") ?? throw new InvalidOperationException("JWT_SECRET is not set");
string host = Environment.GetEnvironmentVariable("HOST") ?? "127.0.0.1";
int port = int.TryParse(Environment.GetEnvironmentVariable("PORT"), out int p) ? p : 3000;

// .NET opens stderr on first use, which needs a free fd: open it now.
Console.Error.Flush();

Db db = new(sqlitePath);
Api api = new(db, new Jwt(Encoding.UTF8.GetBytes(secret)));

WebApplicationBuilder builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions());
builder.WebHost.UseKestrelCore();
builder.Services.AddSingleton<IConnectionListenerFactory>(new UringTransportFactory(host, api, db));
builder.WebHost.ConfigureKestrel(o => {
    o.AddServerHeader = false;
    o.Listen(IPAddress.Parse(host), port);
});
WebApplication app = builder.Build();
await app.Services.GetRequiredService<IServer>().StartAsync(new Unused(), CancellationToken.None);
Console.WriteLine($"listening on {host}:{port}");
await Task.Delay(Timeout.Infinite);

/// <summary>Kestrel needs an application to start. It never runs: the transport answers every request itself.</summary>
internal sealed class Unused : IHttpApplication<object> {
    public object CreateContext(IFeatureCollection contextFeatures) => new();
    public Task ProcessRequestAsync(object context) => Task.CompletedTask;
    public void DisposeContext(object context, Exception? exception) { }
}

/// <summary>Kestrel's transport slot: binds through our loop. The loop keeps every connection from accept to close.</summary>
internal sealed class UringTransportFactory(string host, Api api, Db db) : IConnectionListenerFactory {
    public ValueTask<IConnectionListener> BindAsync(EndPoint endpoint, CancellationToken cancellationToken = default) {
        IPEndPoint ip = endpoint as IPEndPoint ?? throw new NotSupportedException("IP endpoints only");
        Loop loop = new(host, ip.Port, api, db);
        loop.Start();
        return ValueTask.FromResult<IConnectionListener>(new Listener(ip));
    }

    /// <summary>
    /// Kestrel's accept never completes: handing it each connection would wake a thread-pool thread per accept, which on one
    /// core spins against the loop (fsharp-kestrel-delneg measured 44 to 32 µs per new connection).
    /// </summary>
    private sealed class Listener(EndPoint endpoint) : IConnectionListener {
        private readonly TaskCompletionSource<ConnectionContext?> _never = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public EndPoint EndPoint => endpoint;
        public ValueTask<ConnectionContext?> AcceptAsync(CancellationToken cancellationToken = default) => new(_never.Task);
        public ValueTask UnbindAsync(CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
