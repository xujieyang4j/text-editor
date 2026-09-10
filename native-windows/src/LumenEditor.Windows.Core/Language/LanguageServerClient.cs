using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using LumenEditor.Windows.Core.Workspace;

namespace LumenEditor.Windows.Core.Language;

public sealed record LanguageServerConfiguration(string Command, IReadOnlyList<string> Arguments);

public sealed record LanguageServerDocument(string Path, string LanguageId, string Content, int Version);

/// <summary>Persistent, bounded stdio JSON-RPC language-server client.</summary>
public sealed class LanguageServerClient : IAsyncDisposable
{
    public static readonly TimeSpan InitializeTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(15);
    public const int MaximumLogCharacters = 256 * 1024;
    private readonly string root;
    private readonly LanguageServerConfiguration configuration;
    private readonly Process process;
    private readonly SemaphoreSlim writerGate = new(1, 1);
    private readonly SemaphoreSlim documentGate = new(1, 1);
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> pending = new();
    private readonly ConcurrentDictionary<string, LanguageServerDocument> documents = new(StringComparer.OrdinalIgnoreCase);
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task readTask;
    private readonly Task errorTask;
    private long nextId;
    private int logCharacters;
    private bool disposed;

    private LanguageServerClient(
        string root,
        LanguageServerConfiguration configuration,
        Process process,
        Action<string>? onLog)
    {
        this.root = root;
        this.configuration = configuration;
        this.process = process;
        OnLog = onLog;
        readTask = ReadMessagesAsync();
        errorTask = ReadErrorsAsync();
    }

    public Action<string>? OnLog { get; }
    public event Action<JsonElement>? NotificationReceived;
    public bool IsRunning => !disposed && !process.HasExited;

    public LanguageServerDocument? SynchronizedDocument(string path)
    {
        var fullPath = Path.GetFullPath(path);
        return documents.TryGetValue(fullPath, out var document) ? document : null;
    }

    public static async Task<LanguageServerClient> StartAsync(
        string root,
        LanguageServerConfiguration configuration,
        Action<string>? onLog = null,
        CancellationToken cancellationToken = default)
    {
        var normalizedRoot = WorkspaceRoots.Normalize([root]).FirstOrDefault()
            ?? throw new DirectoryNotFoundException("Language-server workspace root is unavailable.");
        if (String.IsNullOrWhiteSpace(configuration.Command) || configuration.Command.Length > 32 * 1024
            || configuration.Arguments.Count > 256 || configuration.Arguments.Any(argument => argument.Length > 32 * 1024))
        {
            throw new ArgumentException("Language-server command is invalid.", nameof(configuration));
        }
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = configuration.Command,
                WorkingDirectory = normalizedRoot,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            },
            EnableRaisingEvents = true
        };
        foreach (var argument in configuration.Arguments) process.StartInfo.ArgumentList.Add(argument);
        try
        {
            if (!process.Start()) throw new InvalidOperationException("Language server did not start.");
            var client = new LanguageServerClient(normalizedRoot, configuration, process, onLog);
            try
            {
                using var initializeDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                initializeDeadline.CancelAfter(InitializeTimeout);
                var response = await client.RequestAsync("initialize", new
                {
                    processId = Environment.ProcessId,
                    rootUri = new Uri(normalizedRoot).AbsoluteUri,
                    capabilities = new { }
                }, InitializeTimeout, initializeDeadline.Token);
                if (response.ValueKind != JsonValueKind.Object)
                {
                    throw new InvalidDataException("Language server returned an invalid initialize response.");
                }
                await client.NotifyAsync("initialized", new { }, cancellationToken);
                return client;
            }
            catch
            {
                await client.DisposeAsync();
                throw;
            }
        }
        catch
        {
            process.Dispose();
            throw;
        }
    }

    public async Task SyncDocumentAsync(
        string path, string languageId, string content, CancellationToken cancellationToken = default)
    {
        ThrowIfUnavailable();
        var fullPath = Path.GetFullPath(path);
        if (!WorkspaceTree.IsInside(root, fullPath))
        {
            throw new InvalidOperationException("Language-server document is outside its workspace root.");
        }
        if (Encoding.UTF8.GetByteCount(content) > LspProtocolLimits.MaximumPayloadBytes / 2)
        {
            throw new InvalidOperationException("Document is too large for language-server synchronization.");
        }
        await documentGate.WaitAsync(cancellationToken);
        try
        {
            var uri = new Uri(fullPath).AbsoluteUri;
            if (!documents.TryGetValue(fullPath, out var previous))
            {
                var document = new LanguageServerDocument(fullPath, languageId, content, 1);
                documents[fullPath] = document;
                await NotifyAsync("textDocument/didOpen", new
                {
                    textDocument = new { uri, languageId, version = document.Version, text = content }
                }, cancellationToken);
                return;
            }
            if (StringComparer.Ordinal.Equals(previous.Content, content) && previous.LanguageId == languageId) return;
            var nextVersion = checked(previous.Version + 1);
            documents[fullPath] = previous with { Content = content, LanguageId = languageId, Version = nextVersion };
            await NotifyAsync("textDocument/didChange", new
            {
                textDocument = new { uri, version = nextVersion },
                contentChanges = new[] { new { text = content } }
            }, cancellationToken);
        }
        finally { documentGate.Release(); }
    }

    public async Task CloseDocumentAsync(string path, CancellationToken cancellationToken = default)
    {
        var fullPath = Path.GetFullPath(path);
        await documentGate.WaitAsync(cancellationToken);
        try
        {
            if (!documents.TryRemove(fullPath, out _)) return;
            await NotifyAsync("textDocument/didClose", new
            {
                textDocument = new { uri = new Uri(fullPath).AbsoluteUri }
            }, cancellationToken);
        }
        finally { documentGate.Release(); }
    }

    public async Task<JsonElement> RequestDocumentAsync(
        string method,
        string path,
        int zeroBasedLine,
        int zeroBasedCharacter,
        object? extra = null,
        CancellationToken cancellationToken = default)
    {
        var fullPath = Path.GetFullPath(path);
        if (!documents.ContainsKey(fullPath)) throw new InvalidOperationException("Document must be synchronized before requesting language features.");
        var parameters = new Dictionary<string, object?>
        {
            ["textDocument"] = new { uri = new Uri(fullPath).AbsoluteUri },
            ["position"] = new { line = Math.Max(0, zeroBasedLine), character = Math.Max(0, zeroBasedCharacter) }
        };
        if (extra is not null)
        {
            foreach (var property in extra.GetType().GetProperties()) parameters[property.Name] = property.GetValue(extra);
        }
        return await RequestAsync(method, parameters, RequestTimeout, cancellationToken);
    }

    public Task<JsonElement> RequestFormattingAsync(
        string path, int tabSize, bool insertSpaces, CancellationToken cancellationToken = default)
    {
        var fullPath = Path.GetFullPath(path);
        if (!documents.ContainsKey(fullPath)) throw new InvalidOperationException("Document must be synchronized before formatting.");
        return RequestAsync("textDocument/formatting", new
        {
            textDocument = new { uri = new Uri(fullPath).AbsoluteUri },
            options = new { tabSize = Math.Clamp(tabSize, 1, 16), insertSpaces }
        }, RequestTimeout, cancellationToken);
    }

    public async Task<JsonElement> RequestAsync(
        string method,
        object? parameters,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        ThrowIfUnavailable();
        var id = Interlocked.Increment(ref nextId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!pending.TryAdd(id, completion)) throw new InvalidOperationException("Duplicate language-server request ID.");
        try
        {
            await WriteAsync(new { jsonrpc = "2.0", id, method, @params = parameters }, cancellationToken);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
            deadline.CancelAfter(timeout);
            try { return await completion.Task.WaitAsync(deadline.Token); }
            catch (OperationCanceledException)
            {
                await TryNotifyCancellationAsync(id);
                throw;
            }
        }
        finally { pending.TryRemove(id, out _); }
    }

    public Task NotifyAsync(string method, object? parameters, CancellationToken cancellationToken = default) =>
        WriteAsync(new { jsonrpc = "2.0", method, @params = parameters }, cancellationToken);

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true;
        try
        {
            if (!process.HasExited)
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                try
                {
                    _ = await RequestAsyncBeforeDispose("shutdown", null, deadline.Token);
                    await WriteAsyncBeforeDispose(new { jsonrpc = "2.0", method = "exit", @params = (object?)null }, deadline.Token);
                    process.StandardInput.Close();
                    await process.WaitForExitAsync(deadline.Token);
                }
                catch (Exception error) when (error is OperationCanceledException or IOException or InvalidOperationException) { }
            }
        }
        finally
        {
            lifetime.Cancel();
            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); }
                catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            }
            FailPending(new ObjectDisposedException(nameof(LanguageServerClient)));
            try { await Task.WhenAll(readTask, errorTask).WaitAsync(TimeSpan.FromSeconds(2)); }
            catch (Exception error) when (error is TimeoutException or OperationCanceledException or IOException) { }
            process.Dispose();
            writerGate.Dispose();
            documentGate.Dispose();
            lifetime.Dispose();
        }
    }

    private async Task<JsonElement> RequestAsyncBeforeDispose(string method, object? parameters, CancellationToken cancellationToken)
    {
        var id = Interlocked.Increment(ref nextId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = completion;
        try
        {
            await WriteAsyncBeforeDispose(new { jsonrpc = "2.0", id, method, @params = parameters }, cancellationToken);
            return await completion.Task.WaitAsync(cancellationToken);
        }
        finally { pending.TryRemove(id, out _); }
    }

    private async Task TryNotifyCancellationAsync(long id)
    {
        try { await WriteAsyncBeforeDispose(new { jsonrpc = "2.0", method = "$/cancelRequest", @params = new { id } }, CancellationToken.None); }
        catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException) { }
    }

    private Task WriteAsync(object message, CancellationToken cancellationToken)
    {
        ThrowIfUnavailable();
        return WriteAsyncBeforeDispose(message, cancellationToken);
    }

    private async Task WriteAsyncBeforeDispose(object message, CancellationToken cancellationToken)
    {
        var frame = LspMessageReader.Encode(message);
        await writerGate.WaitAsync(cancellationToken);
        try
        {
            await process.StandardInput.BaseStream.WriteAsync(frame, cancellationToken);
            await process.StandardInput.BaseStream.FlushAsync(cancellationToken);
        }
        finally { writerGate.Release(); }
    }

    private async Task ReadMessagesAsync()
    {
        var reader = new LspMessageReader();
        var bytes = new byte[16 * 1024];
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var count = await process.StandardOutput.BaseStream.ReadAsync(bytes, lifetime.Token);
                if (count == 0) break;
                var output = reader.Append(bytes.AsSpan(0, count));
                foreach (var error in output.Errors)
                {
                    Log($"LSP protocol error: {error.Message}\n");
                    if (error.Fatal) throw new InvalidDataException(error.Message);
                }
                foreach (var message in output.Messages) HandleMessage(message);
            }
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or InvalidDataException)
        {
            if (!disposed) Log($"Language server output ended: {error.Message}\n");
        }
        finally
        {
            if (!disposed) FailPending(new IOException("Language server output closed."));
        }
    }

    private async Task ReadErrorsAsync()
    {
        var characters = new char[4_096];
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var count = await process.StandardError.ReadAsync(characters, lifetime.Token);
                if (count == 0) break;
                Log(new string(characters, 0, count));
            }
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or ObjectDisposedException) { }
    }

    private void HandleMessage(JsonElement message)
    {
        if (message.TryGetProperty("id", out var idElement) && idElement.TryGetInt64(out var id)
            && !message.TryGetProperty("method", out _))
        {
            if (!pending.TryGetValue(id, out var completion)) return;
            if (message.TryGetProperty("error", out var error))
            {
                completion.TrySetException(new InvalidOperationException(LanguageServerResults.ErrorMessage(error)));
            }
            else if (message.TryGetProperty("result", out var result)) completion.TrySetResult(result.Clone());
            else completion.TrySetException(new InvalidDataException("Language server response has no result or error."));
            return;
        }
        if (message.TryGetProperty("id", out var requestId)
            && message.TryGetProperty("method", out var requestMethod)
            && requestMethod.ValueKind == JsonValueKind.String)
        {
            _ = RespondToServerRequestAsync(requestId.Clone(), requestMethod.GetString() ?? String.Empty, message);
            return;
        }
        NotificationReceived?.Invoke(message.Clone());
    }

    private async Task RespondToServerRequestAsync(JsonElement id, string method, JsonElement message)
    {
        try
        {
            object? result = method switch
            {
                "workspace/configuration" => ConfigurationResponse(message),
                "window/workDoneProgress/create" or "client/registerCapability"
                    or "client/unregisterCapability" => null,
                "workspace/applyEdit" => new { applied = false, failureReason = "The editor requires an explicit user confirmation before applying workspace edits." },
                _ => null
            };
            if (method is "workspace/configuration" or "window/workDoneProgress/create"
                or "client/registerCapability" or "client/unregisterCapability" or "workspace/applyEdit")
            {
                await WriteAsyncBeforeDispose(new { jsonrpc = "2.0", id, result }, lifetime.Token);
            }
            else
            {
                await WriteAsyncBeforeDispose(new
                {
                    jsonrpc = "2.0",
                    id,
                    error = new { code = -32601, message = $"Client method is not supported: {method}" }
                }, lifetime.Token);
            }
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException or OperationCanceledException)
        {
            if (!disposed) Log($"Could not respond to language-server request: {error.Message}\n");
        }
    }

    private static object?[] ConfigurationResponse(JsonElement message)
    {
        if (!message.TryGetProperty("params", out var parameters)
            || !parameters.TryGetProperty("items", out var items)
            || items.ValueKind != JsonValueKind.Array) return [];
        return new object?[Math.Min(items.GetArrayLength(), 128)];
    }

    private void FailPending(Exception error)
    {
        foreach (var completion in pending.Values) completion.TrySetException(error);
        pending.Clear();
    }

    private void Log(string text)
    {
        if (OnLog is null || String.IsNullOrEmpty(text) || logCharacters >= MaximumLogCharacters) return;
        var remaining = MaximumLogCharacters - logCharacters;
        var bounded = text[..Math.Min(remaining, text.Length)];
        logCharacters += bounded.Length;
        OnLog(bounded);
        if (bounded.Length < text.Length) OnLog("\n[Language-server log truncated.]\n");
    }

    private void ThrowIfUnavailable()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (process.HasExited) throw new InvalidOperationException("Language server is not running.");
    }
}
