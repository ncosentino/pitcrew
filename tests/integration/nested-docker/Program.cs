using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using DotNet.Testcontainers.Containers;
using MySqlConnector;
using Testcontainers.MariaDb;

const string databaseImage =
    "mariadb:11.4.5@sha256:49117dcc565cf51aa57ac5fca59ab31213402ff0eae6ffc13c46a37b938f7e4b";
const string reaperImage =
    "testcontainers/ryuk:0.14.0@sha256:7c1a8a9a47c780ed0f983770a662f80deb115d95cce3e2daa3d12115b8cd28f0";
using var shutdown = new CancellationTokenSource();
using var termination = PosixSignalRegistration.Create(
    PosixSignal.SIGTERM, signal => { signal.Cancel = true; shutdown.Cancel(); });
Console.CancelKeyPress += (_, signal) => { signal.Cancel = true; shutdown.Cancel(); };
var token = shutdown.Token;
var mode = args.Single();
try
{
    if (Environment.GetEnvironmentVariable("TESTCONTAINERS_RYUK_DISABLED") is not null)
    {
        throw new InvalidOperationException("The resource reaper must remain enabled.");
    }
    await PhaseAsync("database-image-acquisition",
        () => DockerAsync(["pull", databaseImage], token));
    await PhaseAsync("reaper-image-acquisition",
        () => DockerAsync(["pull", reaperImage], token));
    await using var database = new MariaDbBuilder(databaseImage)
        .WithDatabase("qualification")
        .WithUsername("qualification")
        .WithPassword("synthetic-qualification-only")
        .WithLabel("pitcrew.nested-proof", "true")
        .Build();
    await PhaseAsync("database-readiness", () => database.StartAsync(token));
    var databasePid = (await DockerAsync(
        ["inspect", "--format", "{{.State.Pid}}", database.Id], token)).Trim();
    if (!int.TryParse(databasePid, out var pid) || pid < 1 ||
        !(await File.ReadAllTextAsync($"/proc/{pid}/cgroup", token))
            .StartsWith("0::/pitcrew-containers/", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("Database process escaped the worker-owned cgroup subtree.");
    }
    Console.WriteLine("[pitcrew:nested-smoke] phase=database-accounting status=passed scope=worker-descendant");
    var reaper = await DockerAsync(
        ["ps", "--quiet", "--filter", $"name=testcontainers-ryuk-{ResourceReaper.DefaultSessionId:D}"],
        token);
    if (string.IsNullOrWhiteSpace(reaper))
    {
        throw new InvalidOperationException("The active resource reaper was not observed.");
    }
    Console.WriteLine("[pitcrew:nested-smoke] phase=reaper status=running");
    var connectionString = new MySqlConnectionStringBuilder(database.GetConnectionString())
    {
        Server = database.Hostname,
        Port = database.GetMappedPublicPort(3306),
    };
    await using var connection = new MySqlConnection(connectionString.ConnectionString);
    await connection.OpenAsync(token);
    await PhaseAsync("seeding", async () =>
    {
        await using var seed = connection.CreateCommand();
        seed.CommandText = "CREATE TABLE qualification_marker (value INT NOT NULL); INSERT INTO qualification_marker VALUES (42);";
        await seed.ExecuteNonQueryAsync(token);
    });
    await PhaseAsync("sql-round-trip", async () =>
    {
        await using var query = connection.CreateCommand();
        query.CommandText = "SELECT SUM(value) FROM qualification_marker;";
        var result = Convert.ToInt32(await query.ExecuteScalarAsync(token), CultureInfo.InvariantCulture);
        if (result != 42)
        {
            throw new InvalidOperationException("The isolated SQL round trip returned an unexpected result.");
        }
    });
    Console.WriteLine($"[pitcrew:nested-smoke] cache={mode} selected_tests=1 sql_round_trip=passed");
    if (mode == "abort")
    {
        Console.WriteLine("[pitcrew:nested-smoke] phase=failure-injection status=abrupt-client-exit");
        Environment.Exit(23);
    }
    await connection.CloseAsync();
    await PhaseAsync("database-stop", () => database.StopAsync(token));
    Console.WriteLine("[pitcrew:nested-smoke] phase=complete status=passed");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine($"[pitcrew:nested-smoke] phase=execution status=failed category={error.GetType().Name}");
    return 1;
}

static async Task PhaseAsync(string phase, Func<Task> action)
{
    var elapsed = Stopwatch.StartNew();
    Console.WriteLine($"[pitcrew:nested-smoke] phase={phase} status=started");
    await action();
    Console.WriteLine($"[pitcrew:nested-smoke] phase={phase} status=passed elapsed_ms={elapsed.ElapsedMilliseconds}");
}

static async Task<string> DockerAsync(string[] arguments, CancellationToken token)
{
    using var process = new Process
    {
        StartInfo = new ProcessStartInfo("docker")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        },
    };
    foreach (var argument in arguments)
    {
        process.StartInfo.ArgumentList.Add(argument);
    }
    process.Start();
    var output = process.StandardOutput.ReadToEndAsync(token);
    var errors = process.StandardError.ReadToEndAsync(token);
    await process.WaitForExitAsync(token);
    var result = await output;
    await errors;
    if (process.ExitCode != 0)
    {
        throw new InvalidOperationException("A fixture-owned Docker operation failed.");
    }
    return result;
}
