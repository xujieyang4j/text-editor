using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace LumenEditor.Windows.Core.Parsing;

/// <summary>Serialized, timeout-bounded transport to the native parser helper.</summary>
public sealed class CodeMirrorParserWorkerProcess : IAsyncDisposable
{
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(7);
    private readonly Process process;
    private readonly SemaphoreSlim requestGate = new(1, 1);
    private readonly StringBuilder standardError = new();
    private readonly Task errorPump;
    private IntPtr jobHandle;
    private bool disposed;
    private bool faulted;

    private CodeMirrorParserWorkerProcess(Process process, IntPtr jobHandle)
    {
        this.process = process;
        this.jobHandle = jobHandle;
        errorPump = PumpErrorAsync();
    }

    public bool IsUsable => !disposed && !faulted && !process.HasExited;

    public static Task<CodeMirrorParserWorkerProcess> StartAsync(
        string executable, string bundlePath, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("Parser workers require Windows.");
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable)
            || !Path.IsPathFullyQualified(bundlePath) || !File.Exists(bundlePath))
            throw new FileNotFoundException("The parser executable or bundle is missing.");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true, CreateNoWindow = true
        };
        start.ArgumentList.Add("--parser-worker");
        start.ArgumentList.Add(Path.GetFullPath(bundlePath));
        var process = new Process { StartInfo = start, EnableRaisingEvents = true };
        IntPtr job = IntPtr.Zero;
        try
        {
            if (!process.Start()) throw new InvalidOperationException("Parser worker did not start.");
            job = WindowsKillJob.Assign(process);
            return Task.FromResult(new CodeMirrorParserWorkerProcess(process, job));
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            process.Dispose();
            if (job != IntPtr.Zero) WindowsKillJob.Close(job);
            throw;
        }
    }

    public async Task<CodeMirrorParserAnalysis?> AnalyzeAsync(
        string text, string language, int tabWidth, int indentWidth, bool insertSpaces,
        CancellationToken cancellationToken = default,
        IReadOnlyList<int>? newlineIndentationPositions = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var request = new CodeMirrorParserRequest(CodeMirrorParserProtocol.Version,
            Guid.NewGuid().ToString("N"), text, language, tabWidth, indentWidth, insertSpaces,
            newlineIndentationPositions);
        var encoded = CodeMirrorParserCodec.EncodeRequest(request);
        await requestGate.WaitAsync(cancellationToken);
        try
        {
            // Once a request owns the serial worker, finish it under the hard
            // deadline. UI debounce cancellation discards the stale result but
            // must not tear down the shared process during ordinary typing.
            using var timeout = new CancellationTokenSource(RequestTimeout);
            await process.StandardInput.WriteLineAsync(encoded.AsMemory(), timeout.Token);
            await process.StandardInput.FlushAsync(timeout.Token);
            var line = await ReadBoundedLineAsync(process.StandardOutput.BaseStream,
                CodeMirrorParserProtocol.MaximumTransportResponseUtf8Bytes, timeout.Token);
            var response = CodeMirrorParserCodec.DecodeResponse(line);
            if (!StringComparer.Ordinal.Equals(response.RequestId, request.RequestId))
                throw new InvalidDataException("Parser response did not match the active request.");
            if (response.Error is not null) throw new InvalidOperationException(response.Error);
            return response.Result?.Validate(text, language)
                ?? throw new InvalidDataException("Parser response failed validation.");
        }
        catch
        {
            Kill();
            throw;
        }
        finally { requestGate.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true;
        try
        {
            process.StandardInput.Close();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            await process.WaitForExitAsync(timeout.Token);
        }
        catch { Kill(); }
        try { await errorPump.ConfigureAwait(false); } catch { }
        if (jobHandle != IntPtr.Zero) { WindowsKillJob.Close(jobHandle); jobHandle = IntPtr.Zero; }
        process.Dispose();
        requestGate.Dispose();
    }

    public void Terminate()
    {
        if (disposed) return;
        disposed = true;
        Kill();
        if (jobHandle != IntPtr.Zero) { WindowsKillJob.Close(jobHandle); jobHandle = IntPtr.Zero; }
    }

    private async Task PumpErrorAsync()
    {
        var buffer = new char[2_048];
        while (!process.HasExited && standardError.Length < 256 * 1024)
        {
            var read = await process.StandardError.ReadAsync(buffer);
            if (read == 0) break;
            standardError.Append(buffer, 0, Math.Min(read, 256 * 1024 - standardError.Length));
        }
    }

    private static async Task<string> ReadBoundedLineAsync(Stream stream, int maximumBytes, CancellationToken token)
    {
        using var line = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, token);
            if (read == 0) throw new IOException("Parser worker exited before returning a response.");
            var newline = Array.IndexOf(buffer, (byte)0x0a, 0, read);
            var accepted = newline >= 0 ? newline : read;
            line.Write(buffer, 0, accepted);
            if (line.Length > maximumBytes)
                throw new InvalidDataException("Parser worker response exceeded its size limit.");
            if (newline >= 0)
            {
                if (newline != read - 1)
                    throw new InvalidDataException("Parser worker emitted data after its response.");
                break;
            }
        }
        var bytes = line.ToArray();
        var length = bytes.Length > 0 && bytes[^1] == 0x0d ? bytes.Length - 1 : bytes.Length;
        try { return new UTF8Encoding(false, true).GetString(bytes, 0, length); }
        catch (DecoderFallbackException error)
        {
            throw new InvalidDataException("Parser worker response was not valid UTF-8.", error);
        }
    }

    private void Kill()
    {
        faulted = true;
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
    }

    private static class WindowsKillJob
    {
        private const uint KillOnClose = 0x00002000;
        private const uint ProcessMemory = 0x00000100;
        public static IntPtr Assign(Process process)
        {
            var handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            var limits = new JobObjectExtendedLimitInformation
            {
                BasicLimitInformation = new BasicLimit { LimitFlags = KillOnClose | ProcessMemory },
                ProcessMemoryLimit = (UIntPtr)(512UL * 1024 * 1024)
            };
            var bytes = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
            var memory = Marshal.AllocHGlobal(bytes);
            try
            {
                Marshal.StructureToPtr(limits, memory, false);
                if (!SetInformationJobObject(handle, 9, memory, (uint)bytes)
                    || !AssignProcessToJobObject(handle, process.Handle))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return handle;
            }
            catch { CloseHandle(handle); throw; }
            finally { Marshal.FreeHGlobal(memory); }
        }
        public static void Close(IntPtr handle) => CloseHandle(handle);
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimit
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)] private struct JobObjectExtendedLimitInformation
        {
            public BasicLimit BasicLimitInformation; public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    }
}
