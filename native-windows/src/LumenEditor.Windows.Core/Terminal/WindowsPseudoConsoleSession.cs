using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace LumenEditor.Windows.Core.Terminal;

public static class WindowsCommandLine
{
    public static string Quote(string argument)
    {
        if (argument.Length > 0 && !argument.Any(character => Char.IsWhiteSpace(character) || character == '"'))
        {
            return argument;
        }
        var result = new StringBuilder(argument.Length + 2).Append('"');
        var slashes = 0;
        foreach (var character in argument)
        {
            if (character == '\\')
            {
                slashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', slashes * 2 + 1).Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes).Append(character);
            slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('"');
        return result.ToString();
    }

    public static string Create(string executable, IEnumerable<string> arguments) =>
        String.Join(' ', new[] { Quote(executable) }.Concat(arguments.Select(Quote)));
}

/// <summary>Native Windows ConPTY session owned by a kill-on-close Job Object.</summary>
public sealed class WindowsPseudoConsoleSession : IAsyncDisposable, IDisposable
{
    public const int MaximumInputCharacters = 64 * 1024;
    public const int MaximumOutputCharacters = 1_000_000;
    private const int ProcThreadAttributePseudoConsole = 0x00020016;
    private const uint ExtendedStartupInfoPresent = 0x00080000;
    private const uint CreateUnicodeEnvironment = 0x00000400;
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const uint Infinite = 0xFFFFFFFF;

    private readonly object gate = new();
    private readonly Action<string> output;
    private readonly FileStream input;
    private readonly FileStream terminalOutput;
    private readonly CancellationTokenSource lifetime = new();
    private IntPtr pseudoConsole;
    private IntPtr processHandle;
    private IntPtr jobHandle;
    private int deliveredCharacters;
    private bool outputTruncated;
    private bool disposed;

    public WindowsPseudoConsoleSession(
        string executable,
        IReadOnlyList<string> arguments,
        string workingDirectory,
        Action<string> output,
        int columns = 120,
        int rows = 30)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("ConPTY requires Windows 10 1809 or newer.");
        var root = Path.GetFullPath(workingDirectory);
        if (!Directory.Exists(root)) throw new DirectoryNotFoundException(root);
        this.output = output ?? throw new ArgumentNullException(nameof(output));
        SafeFileHandle? inputRead = null;
        SafeFileHandle? inputWrite = null;
        SafeFileHandle? outputRead = null;
        SafeFileHandle? outputWrite = null;
        IntPtr attributes = IntPtr.Zero;
        IntPtr pseudoConsoleValue = IntPtr.Zero;
        try
        {
            ThrowIfFalse(CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0));
            ThrowIfFalse(CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0));
            ThrowIfFailed(CreatePseudoConsole(
                new Coord((short)Math.Clamp(columns, 1, Int16.MaxValue), (short)Math.Clamp(rows, 1, Int16.MaxValue)),
                inputRead.DangerousGetHandle(), outputWrite.DangerousGetHandle(), 0, out pseudoConsole));
            inputRead.Dispose();
            inputRead = null;
            outputWrite.Dispose();
            outputWrite = null;

            nuint attributeBytes = 0;
            _ = InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeBytes);
            attributes = Marshal.AllocHGlobal(checked((int)attributeBytes));
            ThrowIfFalse(InitializeProcThreadAttributeList(attributes, 1, 0, ref attributeBytes));
            pseudoConsoleValue = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(pseudoConsoleValue, pseudoConsole);
            ThrowIfFalse(UpdateProcThreadAttribute(
                attributes, 0, (IntPtr)ProcThreadAttributePseudoConsole, pseudoConsoleValue,
                (nuint)IntPtr.Size, IntPtr.Zero, IntPtr.Zero));
            var startup = new StartupInfoEx
            {
                StartupInfo = new StartupInfo { Size = Marshal.SizeOf<StartupInfoEx>() },
                AttributeList = attributes
            };
            var commandLine = new StringBuilder(WindowsCommandLine.Create(executable, arguments));
            ThrowIfFalse(CreateProcess(
                executable, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                ExtendedStartupInfoPresent | CreateUnicodeEnvironment, IntPtr.Zero, root,
                ref startup, out var process));
            processHandle = process.Process;
            CloseHandle(process.Thread);

            jobHandle = CreateJobObject(IntPtr.Zero, null);
            if (jobHandle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            var limits = new JobObjectExtendedLimitInformation
            {
                BasicLimitInformation = new JobObjectBasicLimitInformation
                {
                    LimitFlags = JobObjectLimitKillOnJobClose
                }
            };
            var size = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
            var memory = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, memory, false);
                ThrowIfFalse(SetInformationJobObject(jobHandle, 9, memory, (uint)size));
                ThrowIfFalse(AssignProcessToJobObject(jobHandle, processHandle));
            }
            finally { Marshal.FreeHGlobal(memory); }

            input = new FileStream(inputWrite, FileAccess.Write, 4_096, isAsync: false);
            inputWrite = null;
            terminalOutput = new FileStream(outputRead, FileAccess.Read, 4_096, isAsync: false);
            outputRead = null;
            Completion = Task.WhenAll(PumpOutputAsync(), WaitForExitAsync());
        }
        catch
        {
            inputRead?.Dispose();
            inputWrite?.Dispose();
            outputRead?.Dispose();
            outputWrite?.Dispose();
            if (processHandle != IntPtr.Zero) CloseHandle(processHandle);
            if (jobHandle != IntPtr.Zero) CloseHandle(jobHandle);
            if (pseudoConsole != IntPtr.Zero) ClosePseudoConsole(pseudoConsole);
            throw;
        }
        finally
        {
            if (attributes != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(attributes);
                Marshal.FreeHGlobal(attributes);
            }
            if (pseudoConsoleValue != IntPtr.Zero) Marshal.FreeHGlobal(pseudoConsoleValue);
        }
    }

    public Task Completion { get; }

    public async Task WriteAsync(string text, CancellationToken cancellationToken = default)
    {
        if (String.IsNullOrEmpty(text) || text.Length > MaximumInputCharacters)
        {
            throw new ArgumentException("Terminal input must contain 1 to 65536 characters.", nameof(text));
        }
        ObjectDisposedException.ThrowIf(disposed, this);
        var bytes = Encoding.UTF8.GetBytes(text);
        await input.WriteAsync(bytes, cancellationToken);
        await input.FlushAsync(cancellationToken);
    }

    public void Resize(int columns, int rows)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        ThrowIfFailed(ResizePseudoConsole(
            pseudoConsole, new Coord((short)Math.Clamp(columns, 1, Int16.MaxValue), (short)Math.Clamp(rows, 1, Int16.MaxValue))));
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            lifetime.Cancel();
            input.Dispose();
            if (jobHandle != IntPtr.Zero)
            {
                CloseHandle(jobHandle);
                jobHandle = IntPtr.Zero;
            }
            if (pseudoConsole != IntPtr.Zero)
            {
                ClosePseudoConsole(pseudoConsole);
                pseudoConsole = IntPtr.Zero;
            }
            terminalOutput.Dispose();
            if (processHandle != IntPtr.Zero)
            {
                CloseHandle(processHandle);
                processHandle = IntPtr.Zero;
            }
            lifetime.Dispose();
        }
    }

    public async ValueTask DisposeAsync()
    {
        Dispose();
        try { await Completion.ConfigureAwait(false); }
        catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or IOException) { }
    }

    private async Task PumpOutputAsync()
    {
        var bytes = new byte[4_096];
        var decoder = Encoding.UTF8.GetDecoder();
        var characters = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var count = await terminalOutput.ReadAsync(bytes, lifetime.Token);
                if (count == 0) return;
                var written = decoder.GetChars(bytes.AsSpan(0, count), characters, flush: false);
                Deliver(new string(characters, 0, written));
            }
        }
        catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or IOException) { }
    }

    private async Task WaitForExitAsync()
    {
        await Task.Run(() => WaitForSingleObject(processHandle, Infinite));
    }

    private void Deliver(string text)
    {
        if (text.Length == 0 || outputTruncated) return;
        var remaining = MaximumOutputCharacters - deliveredCharacters;
        if (remaining <= 0)
        {
            outputTruncated = true;
            output("\n[Terminal output truncated.]\n");
            return;
        }
        var chunk = text[..Math.Min(remaining, text.Length)];
        deliveredCharacters += chunk.Length;
        output(chunk);
        if (chunk.Length < text.Length)
        {
            outputTruncated = true;
            output("\n[Terminal output truncated.]\n");
        }
    }

    private static void ThrowIfFalse(bool result)
    {
        if (!result) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    private static void ThrowIfFailed(int result)
    {
        if (result < 0) Marshal.ThrowExceptionForHR(result);
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct Coord(short X, short Y);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size;
        public string? Reserved;
        public string? Desktop;
        public string? Title;
        public int X; public int Y; public int XSize; public int YSize; public int XCountChars; public int YCountChars;
        public int FillAttribute; public int Flags; public short ShowWindow; public short Reserved2;
        public IntPtr ReservedPointer; public IntPtr StandardInput; public IntPtr StandardOutput; public IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr AttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public IntPtr Process; public IntPtr Thread; public uint ProcessId; public uint ThreadId; }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(Coord size, IntPtr input, IntPtr output, uint flags, out IntPtr handle);
    [DllImport("kernel32.dll")]
    private static extern int ResizePseudoConsole(IntPtr handle, Coord size);
    [DllImport("kernel32.dll")]
    private static extern void ClosePseudoConsole(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr attributes, int count, uint flags, ref nuint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr attributes, uint flags, IntPtr attribute, IntPtr value, nuint size, IntPtr previous, IntPtr returnedSize);
    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributes);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateProcessW")]
    private static extern bool CreateProcess(string? applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string workingDirectory, ref StartupInfoEx startupInfo, out ProcessInformation processInformation);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
