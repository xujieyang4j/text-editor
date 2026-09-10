using System.Diagnostics;
using System.Text;

namespace LumenEditor.Windows.Core.Processes;

public sealed record ProcessRequest(
    string FileName,
    IReadOnlyList<string> Arguments,
    string WorkingDirectory,
    TimeSpan? Timeout = null,
    int MaximumOutputCharacters = 2_000_000,
    IReadOnlyDictionary<string, string?>? Environment = null,
    string? StandardInput = null);

public sealed record ProcessResult(
    bool Started, int? ExitCode, string StandardOutput, string StandardError,
    bool TimedOut = false, bool WasCancelled = false, bool WasTruncated = false, string? Error = null);

/// <summary>Shell-free process execution with bounded output, timeout, cancellation, and process-tree cleanup.</summary>
public sealed class BoundedProcessRunner
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(10);

    public async Task<ProcessResult> RunAsync(
        ProcessRequest request, CancellationToken cancellationToken = default)
    {
        if (String.IsNullOrWhiteSpace(request.FileName))
        {
            return new(false, null, String.Empty, String.Empty, Error: "Executable name is required.");
        }
        string workingDirectory;
        try { workingDirectory = Path.GetFullPath(request.WorkingDirectory); }
        catch (Exception error) when (error is ArgumentException or IOException or NotSupportedException)
        {
            return new(false, null, String.Empty, String.Empty, Error: error.Message);
        }
        if (!Directory.Exists(workingDirectory))
        {
            return new(false, null, String.Empty, String.Empty, Error: "Working directory does not exist.");
        }
        var maximum = Math.Clamp(request.MaximumOutputCharacters, 1_024, 10_000_000);
        var stdout = new BoundedTextAccumulator(maximum);
        var stderr = new BoundedTextAccumulator(maximum);
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = request.FileName,
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true
            },
            EnableRaisingEvents = true
        };
        foreach (var argument in request.Arguments) process.StartInfo.ArgumentList.Add(argument);
        foreach (var pair in request.Environment ?? new Dictionary<string, string?>())
        {
            process.StartInfo.Environment[pair.Key] = pair.Value;
        }
        Task? readOutput = null;
        Task? readError = null;
        try
        {
            if (!process.Start()) return new(false, null, String.Empty, String.Empty, Error: "Process did not start.");
            readOutput = PumpAsync(process.StandardOutput, stdout);
            readError = PumpAsync(process.StandardError, stderr);
            if (request.StandardInput is not null)
            {
                await process.StandardInput.WriteAsync(request.StandardInput);
            }
            process.StandardInput.Close();
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            TryKill(process);
            if (readOutput is not null && readError is not null)
            {
                try { await Task.WhenAll(readOutput, readError); } catch { }
            }
            return new(false, null, String.Empty, String.Empty, Error: error.Message);
        }

        using var timeout = new CancellationTokenSource(request.Timeout ?? DefaultTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
        try
        {
            await process.WaitForExitAsync(linked.Token);
            await Task.WhenAll(readOutput!, readError!);
            return new(true, process.ExitCode, stdout.Text, stderr.Text, WasTruncated: stdout.IsTruncated || stderr.IsTruncated);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            await Task.WhenAll(readOutput!, readError!);
            return new(
                true, process.HasExited ? process.ExitCode : null, stdout.Text, stderr.Text,
                TimedOut: timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested,
                WasCancelled: cancellationToken.IsCancellationRequested,
                WasTruncated: stdout.IsTruncated || stderr.IsTruncated);
        }
    }

    private static async Task PumpAsync(StreamReader reader, BoundedTextAccumulator accumulator)
    {
        var buffer = new char[4_096];
        while (true)
        {
            var count = await reader.ReadAsync(buffer);
            if (count == 0) return;
            accumulator.Append(buffer.AsSpan(0, count));
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
    }

    private sealed class BoundedTextAccumulator(int maximum)
    {
        private readonly StringBuilder builder = new(Math.Min(maximum, 64 * 1024));
        public bool IsTruncated { get; private set; }
        public string Text => builder.ToString();

        public void Append(ReadOnlySpan<char> value)
        {
            var remaining = maximum - builder.Length;
            if (remaining <= 0)
            {
                IsTruncated = true;
                return;
            }
            var count = Math.Min(remaining, value.Length);
            builder.Append(value[..count]);
            if (count < value.Length) IsTruncated = true;
        }
    }
}
