using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;

namespace LumenEditor.Windows.Core.Plugins;

/// <summary>Serialized JSON-lines channel to the app's dedicated plugin-worker process.</summary>
public sealed class PluginWorkerProcess : IAsyncDisposable
{
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(10);
    private readonly Process process;
    private readonly SemaphoreSlim requestGate = new(1, 1);
    private readonly StringBuilder standardError = new();
    private readonly Task errorPump;
    private readonly Channel<string> outputLines = Channel.CreateBounded<string>(new BoundedChannelOptions(
        PluginWorkerProtocol.MaximumMessagesPerRequest + 2)
        { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly Task outputPump;
    private IntPtr jobHandle;
    private bool disposed;

    private PluginWorkerProcess(Process process, IntPtr jobHandle)
    {
        this.process = process;
        this.jobHandle = jobHandle;
        errorPump = PumpErrorAsync();
        outputPump = PumpOutputAsync();
    }

    public IReadOnlyList<PluginWorkerResponse> StartupResponses { get; private set; } = [];

    public static async Task<PluginWorkerProcess> StartAsync(
        string executable, PluginWorkerPackage package, IReadOnlyList<PluginPermission> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Plugin workers require Windows.");
        if (permissions.Any(permission => !package.Permissions.Contains(permission)))
            throw new InvalidDataException("Granted permissions exceed the plugin manifest request.");
        string source;
        try { source = new UTF8Encoding(false, true).GetString(package.Source); }
        catch (DecoderFallbackException error) { throw new InvalidDataException("Plugin worker must be valid UTF-8.", error); }
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true, CreateNoWindow = true
        };
        start.ArgumentList.Add("--plugin-worker");
        start.ArgumentList.Add(package.Manifest.Id);
        start.ArgumentList.Add(package.SourceIntegrity);
        start.ArgumentList.Add(PluginWorkerCodec.EncodePayload(permissions));
        var process = new Process { StartInfo = start, EnableRaisingEvents = true };
        IntPtr job = IntPtr.Zero;
        PluginWorkerProcess? connection = null;
        try
        {
            if (!process.Start()) throw new InvalidOperationException("Plugin worker did not start.");
            job = WindowsKillJob.Assign(process);
            connection = new PluginWorkerProcess(process, job);
            job = IntPtr.Zero;
            var load = new PluginWorkerRequest(PluginWorkerProtocol.Version, PluginWorkerRequestKind.Load,
                RequestId(), source, package.SourceIntegrity);
            connection.StartupResponses = await connection.RequestAsync(load, cancellationToken);
            return connection;
        }
        catch
        {
            if (connection is not null) await connection.DisposeAsync();
            else
            {
                try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
                process.Dispose();
                if (job != IntPtr.Zero) WindowsKillJob.Close(job);
            }
            throw;
        }
    }

    public async Task<IReadOnlyList<PluginWorkerResponse>> RequestAsync(
        PluginWorkerRequest request, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        await requestGate.WaitAsync(cancellationToken);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(RequestTimeout);
            await process.StandardInput.WriteLineAsync(PluginWorkerCodec.Encode(request).AsMemory(), timeout.Token);
            await process.StandardInput.FlushAsync(timeout.Token);
            var responses = new List<PluginWorkerResponse>();
            var bytes = 0;
            while (responses.Count <= PluginWorkerProtocol.MaximumMessagesPerRequest)
            {
                string line;
                try { line = await outputLines.Reader.ReadAsync(timeout.Token); }
                catch (ChannelClosedException error)
                {
                    throw new IOException($"Plugin worker exited early. {Bound(standardError.ToString(), 2_000)}", error);
                }
                bytes += Encoding.UTF8.GetByteCount(line) + 1;
                if (bytes > PluginWorkerProtocol.MaximumResponseBytes)
                    throw new InvalidDataException("Plugin worker response exceeded its cumulative limit.");
                var response = PluginWorkerCodec.DecodeResponse(line);
                if (!StringComparer.Ordinal.Equals(response.RequestId, request.RequestId))
                    throw new InvalidDataException("Plugin worker response did not match the active request.");
                if (response.Type == PluginWorkerResponseKind.Failed)
                    throw new InvalidOperationException(response.Text ?? "Plugin worker failed.");
                if (response.Type == PluginWorkerResponseKind.Completed) return responses;
                responses.Add(response);
            }
            throw new InvalidDataException("Plugin worker emitted too many responses.");
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
            if (!process.HasExited)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                await process.StandardInput.WriteLineAsync(PluginWorkerCodec.Encode(new PluginWorkerRequest(
                    PluginWorkerProtocol.Version, PluginWorkerRequestKind.Deactivate, RequestId())).AsMemory(), timeout.Token);
                await process.StandardInput.FlushAsync(timeout.Token);
                await process.WaitForExitAsync(timeout.Token);
            }
        }
        catch { Kill(); }
        try { await errorPump.ConfigureAwait(false); } catch { }
        try { await outputPump.ConfigureAwait(false); } catch { }
        if (jobHandle != IntPtr.Zero) { WindowsKillJob.Close(jobHandle); jobHandle = IntPtr.Zero; }
        process.Dispose();
        requestGate.Dispose();
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

    private async Task PumpOutputAsync()
    {
        var buffer = new byte[4_096];
        using var line = new MemoryStream();
        try
        {
            while (true)
            {
                var read = await process.StandardOutput.BaseStream.ReadAsync(buffer);
                if (read == 0)
                {
                    if (line.Length > 0) throw new InvalidDataException("Plugin worker ended with an incomplete message.");
                    outputLines.Writer.TryComplete();
                    return;
                }
                for (var index = 0; index < read; index++)
                {
                    if (buffer[index] == 0x0a)
                    {
                        var bytes = line.ToArray();
                        line.SetLength(0);
                        var length = bytes.Length > 0 && bytes[^1] == 0x0d ? bytes.Length - 1 : bytes.Length;
                        if (!outputLines.Writer.TryWrite(new UTF8Encoding(false, true).GetString(bytes, 0, length)))
                            throw new InvalidDataException("Plugin worker output queue exceeded its message limit.");
                    }
                    else
                    {
                        line.WriteByte(buffer[index]);
                        if (line.Length > PluginWorkerProtocol.MaximumMessageBytes)
                            throw new InvalidDataException("Plugin worker emitted an oversized unterminated message.");
                    }
                }
            }
        }
        catch (Exception error)
        {
            outputLines.Writer.TryComplete(error);
            Kill();
        }
    }

    private void Kill()
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
    }

    public void Terminate()
    {
        if (disposed) return;
        disposed = true;
        Kill();
        outputLines.Writer.TryComplete();
        if (jobHandle != IntPtr.Zero) { WindowsKillJob.Close(jobHandle); jobHandle = IntPtr.Zero; }
    }
    private static string RequestId() => Guid.NewGuid().ToString("N");
    private static string Bound(string value, int maximum) => value.Length <= maximum ? value : value[..maximum];

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
