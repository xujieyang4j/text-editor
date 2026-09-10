using System.Text.Json;
using LumenEditor.Windows.Core.Processes;
using LumenEditor.Windows.Core.Workspace;

namespace LumenEditor.Windows.Core.Build;

public sealed record DetectedBuildSystem(
    string Id, string Name, string Executable, IReadOnlyList<string> Arguments, string WorkingDirectory,
    IReadOnlyDictionary<string, string?>? Environment = null, bool SaveBeforeBuild = false)
{
    public string Display => $"{Name} — {Executable} {String.Join(' ', Arguments)}";
    public ProcessRequest ToRequest() => new(Executable, Arguments, WorkingDirectory, Environment: Environment);
}

/// <summary>Detects bounded declarative project builds without interpreting shell command strings.</summary>
public static class BuildSystemDetector
{
    public const int MaximumPackageJsonBytes = 1024 * 1024;

    public static DetectedBuildSystem? FromCommand(string root, string command)
    {
        var normalized = WorkspaceRoots.Normalize([root]).FirstOrDefault();
        var arguments = ParseCommandLine(command);
        return normalized is null || arguments.Count == 0 ? null
            : new("configured-command", "Configured Build Command", arguments[0],
                arguments.Skip(1).ToArray(), normalized);
    }

    public static IReadOnlyList<string> ParseCommandLine(string? command)
    {
        if (String.IsNullOrWhiteSpace(command) || command.Length > 1_000
            || command.Any(character => Char.IsControl(character) && !Char.IsWhiteSpace(character))) return [];
        var arguments = new List<string>();
        var current = new System.Text.StringBuilder();
        char quote = '\0';
        var escaped = false;
        foreach (var character in command)
        {
            if (escaped)
            {
                if (character is '\\' or '"' or '\'') current.Append(character);
                else { current.Append('\\'); current.Append(character); }
                escaped = false;
                continue;
            }
            if (character == '\\') { escaped = true; continue; }
            if (quote != '\0')
            {
                if (character == quote) quote = '\0'; else current.Append(character);
                continue;
            }
            if (character is '"' or '\'') { quote = character; continue; }
            if (Char.IsWhiteSpace(character))
            {
                if (current.Length == 0) continue;
                arguments.Add(current.ToString());
                current.Clear();
                if (arguments.Count > ProjectBuildSettings.MaximumArguments) return [];
                continue;
            }
            current.Append(character);
            if (current.Length > 32 * 1024) return [];
        }
        if (escaped) current.Append('\\');
        if (quote != '\0') return [];
        if (current.Length > 0) arguments.Add(current.ToString());
        return arguments.Count <= ProjectBuildSettings.MaximumArguments + 1 ? arguments : [];
    }

    public static IReadOnlyList<DetectedBuildSystem> Detect(string root)
    {
        var normalized = WorkspaceRoots.Normalize([root]).FirstOrDefault();
        if (normalized is null) return [];
        var systems = new List<DetectedBuildSystem>();
        AddPackageBuild(normalized, systems);
        var solution = Directory.EnumerateFiles(normalized, "*.sln", SearchOption.TopDirectoryOnly)
            .Order(StringComparer.OrdinalIgnoreCase).FirstOrDefault();
        if (solution is not null)
        {
            systems.Add(new("dotnet-solution", $"Build {Path.GetFileName(solution)}", "dotnet",
                ["build", solution], normalized));
        }
        else
        {
            var project = Directory.EnumerateFiles(normalized, "*.csproj", SearchOption.TopDirectoryOnly)
                .Order(StringComparer.OrdinalIgnoreCase).FirstOrDefault();
            if (project is not null)
            {
                systems.Add(new("dotnet-project", $"Build {Path.GetFileName(project)}", "dotnet",
                    ["build", project], normalized));
            }
        }
        AddIfExists(systems, normalized, "Cargo.toml", "cargo", "Cargo Build", "cargo", ["build"]);
        AddIfExists(systems, normalized, "go.mod", "go", "Go Build", "go", ["build", "./..."]);
        AddIfExists(systems, normalized, "CMakeLists.txt", "cmake", "CMake Build", "cmake", ["--build", "build"]);
        AddIfExists(systems, normalized, "Makefile", "make", "Make", "make", []);
        return systems.Take(20).ToList();
    }

    private static void AddPackageBuild(string root, List<DetectedBuildSystem> systems)
    {
        var path = Path.Combine(root, "package.json");
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > MaximumPackageJsonBytes) return;
            using var document = JsonDocument.Parse(File.ReadAllBytes(path));
            if (!document.RootElement.TryGetProperty("scripts", out var scripts)
                || scripts.ValueKind != JsonValueKind.Object
                || !scripts.TryGetProperty("build", out var build)
                || build.ValueKind != JsonValueKind.String
                || String.IsNullOrWhiteSpace(build.GetString())) return;
            // corepack.exe is a real executable on supported Windows Node distributions,
            // allowing npm to run without passing a command string through cmd.exe.
            var executable = OperatingSystem.IsWindows() ? "corepack.exe" : "npm";
            var arguments = OperatingSystem.IsWindows()
                ? new[] { "npm", "run", "build" }
                : new[] { "run", "build" };
            systems.Add(new("npm-build", "npm run build", executable, arguments, root));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            // An unreadable project manifest simply does not contribute a build system.
        }
    }

    private static void AddIfExists(
        List<DetectedBuildSystem> systems, string root, string marker, string id, string name,
        string executable, IReadOnlyList<string> arguments)
    {
        if (File.Exists(Path.Combine(root, marker))) systems.Add(new(id, name, executable, arguments, root));
    }
}
