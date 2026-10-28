#:package Microsoft.Data.SqlClient@5.1.6
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

// Lists the databases whose names match --pattern on the loopback SQL Server named by --server, and drops them
// when --drop is passed. The connection string comes from the environment variable named by --env and is never
// printed. Exit codes: 0 done, 1 refused (not the configured loopback server), 2 connection string missing or
// invalid, 3 bad arguments, 4 SQL error.
const int Refused = 1;
const int ConnectionMissing = 2;
const int BadArguments = 3;
const int SqlFailed = 4;

string? envName = null;
string? server = null;
string? pattern = null;
var drop = false;
for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--env" when i + 1 < args.Length:
            envName = args[++i];
            break;
        case "--server" when i + 1 < args.Length:
            server = args[++i];
            break;
        case "--pattern" when i + 1 < args.Length:
            pattern = args[++i];
            break;
        case "--drop":
            drop = true;
            break;
        default:
            Console.Error.WriteLine($"unknown or incomplete argument: {args[i]}");
            return BadArguments;
    }
}

if (string.IsNullOrWhiteSpace(envName) || string.IsNullOrWhiteSpace(server) || string.IsNullOrWhiteSpace(pattern))
{
    Console.Error.WriteLine("usage: cleanup-test-databases.cs --env <variable> --server <host,port> --pattern <regex> [--drop]");
    return BadArguments;
}

Regex namePattern;
try
{
    namePattern = new Regex(pattern, RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
}
catch (ArgumentException)
{
    Console.Error.WriteLine("--pattern is not a valid regular expression");
    return BadArguments;
}

var connectionString = Environment.GetEnvironmentVariable(envName);
if (string.IsNullOrWhiteSpace(connectionString))
{
    Console.Error.WriteLine($"environment variable {envName} is not set");
    return ConnectionMissing;
}

SqlConnectionStringBuilder builder;
try
{
    builder = new SqlConnectionStringBuilder(connectionString) { InitialCatalog = "master" };
}
catch (ArgumentException)
{
    // The exception text can echo parts of the connection string, so it is not printed.
    Console.Error.WriteLine($"the connection string in {envName} is not valid");
    return ConnectionMissing;
}

if (!IsConfiguredLoopback(builder.DataSource, server))
{
    Console.WriteLine("refusing: not the configured loopback server");
    return Refused;
}

try
{
    await using var connection = new SqlConnection(builder.ConnectionString);
    await connection.OpenAsync();
    var names = new List<string>();
    await using (var list = new SqlCommand("SELECT name FROM sys.databases ORDER BY name", connection))
    await using (var reader = await list.ExecuteReaderAsync())
    {
        while (await reader.ReadAsync())
        {
            var name = reader.GetString(0);
            if (namePattern.IsMatch(name))
            {
                names.Add(name);
            }
        }
    }

    foreach (var name in names)
    {
        Console.WriteLine($"leaked {name}");
        if (drop)
        {
            var quoted = name.Replace("]", "]]", StringComparison.Ordinal);
            await using var command = new SqlCommand($"ALTER DATABASE [{quoted}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{quoted}];", connection);
            await command.ExecuteNonQueryAsync();
            Console.WriteLine($"dropped {name}");
        }
    }

    Console.WriteLine($"count={names.Count}");
    return 0;
}
catch (SqlException ex)
{
    // The message can name the login, so only the error number, class and state are printed.
    Console.Error.WriteLine($"sql error {ex.Number}, class {ex.Class}, state {ex.State}");
    return SqlFailed;
}

// The data source must be exactly the configured server, and that server must be a loopback address, so a
// connection string pointing anywhere else is never opened.
static bool IsConfiguredLoopback(string dataSource, string configuredServer)
{
    if (!string.Equals(dataSource.Trim(), configuredServer.Trim(), StringComparison.OrdinalIgnoreCase))
    {
        return false;
    }

    var host = dataSource.Trim();
    var comma = host.LastIndexOf(',');
    if (comma >= 0)
    {
        host = host[..comma];
    }

    if (host.StartsWith("tcp:", StringComparison.OrdinalIgnoreCase))
    {
        host = host[4..];
    }

    return host.ToLowerInvariant() is "127.0.0.1" or "localhost" or "::1" or "[::1]";
}
