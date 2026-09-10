using System.Text;
using System.Text.Json;
using Jint;

namespace LumenEditor.Windows.Core.Plugins;

/// <summary>Runs plugin JavaScript inside a constrained engine in the dedicated worker process.</summary>
public sealed class PluginWorkerHost
{
    private readonly string pluginId;
    private readonly string expectedIntegrity;
    private readonly HashSet<PluginPermission> allowedPermissions;
    private Engine? engine;
    private string? activeRequestId;
    private Action<PluginWorkerResponse>? emit;
    private int emittedMessages;

    public PluginWorkerHost(
        string pluginId, string expectedIntegrity, IEnumerable<PluginPermission> allowedPermissions)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(pluginId, "^[a-z0-9-]+$",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            throw new ArgumentException("Plugin ID is invalid.", nameof(pluginId));
        if (!PluginIntegrity.IsValid(expectedIntegrity)) throw new ArgumentException("Worker integrity is invalid.", nameof(expectedIntegrity));
        this.pluginId = pluginId;
        this.expectedIntegrity = expectedIntegrity;
        this.allowedPermissions = allowedPermissions.Where(Enum.IsDefined).Distinct().ToHashSet();
    }

    public IReadOnlyList<PluginWorkerResponse> Handle(PluginWorkerRequest request)
    {
        var responses = new List<PluginWorkerResponse>();
        activeRequestId = request.RequestId;
        emit = response =>
        {
            if (emittedMessages >= PluginWorkerProtocol.MaximumMessagesPerRequest)
                throw new InvalidDataException("Plugin emitted too many messages.");
            PluginWorkerCodec.Encode(response);
            responses.Add(response);
            emittedMessages++;
        };
        emittedMessages = 0;
        try
        {
            switch (request.Type)
            {
                case PluginWorkerRequestKind.Load: Load(request); break;
                case PluginWorkerRequestKind.Activate: Dispatch(request, optional: true); break;
                case PluginWorkerRequestKind.RunCommand: Dispatch(request, optional: false); break;
                case PluginWorkerRequestKind.Deactivate: Dispatch(request, optional: true); engine = null; break;
            }
            responses.Add(new(PluginWorkerProtocol.Version, PluginWorkerResponseKind.Completed, request.RequestId));
        }
        catch (Exception error)
        {
            responses.Add(new(PluginWorkerProtocol.Version, PluginWorkerResponseKind.Failed, request.RequestId,
                Text: Bound(error.Message, PluginWorkerProtocol.MaximumFailureCharacters)));
        }
        finally
        {
            activeRequestId = null;
            emit = null;
        }
        return responses;
    }

    private void Load(PluginWorkerRequest request)
    {
        if (engine is not null || request.Source is null || request.SourceIntegrity != expectedIntegrity
            || !PluginIntegrity.Matches(expectedIntegrity, Encoding.UTF8.GetBytes(request.Source)))
            throw new InvalidDataException("Plugin worker load request failed integrity validation.");
        engine = new Engine(options =>
        {
            options.Strict().DisableStringCompilation().LimitMemory(64 * 1024 * 1024)
                .TimeoutInterval(TimeSpan.FromSeconds(5)).MaxStatements(1_000_000).LimitRecursion(128);
            options.Interop.Enabled = false;
        });
        engine.SetValue("__lumenPostMessage", new Action<string>(ReceiveMessage));
        engine.Execute("var self=globalThis;var __lumenListeners=[];"
            + "Object.defineProperty(globalThis,'postMessage',{value:function(v){__lumenPostMessage(JSON.stringify(v));},writable:false,configurable:false});"
            + "globalThis.addEventListener=function(t,f){if(t==='message'&&typeof f==='function')__lumenListeners.push(f);};"
            + "globalThis.removeEventListener=function(t,f){if(t==='message')__lumenListeners=__lumenListeners.filter(function(x){return x!==f;});};"
            + "globalThis.__lumenDispatch=function(j){var m=JSON.parse(j);var e={data:m};if(typeof self.onmessage==='function')self.onmessage(e);__lumenListeners.slice().forEach(function(f){f(e);});};"
            + "globalThis.fetch=undefined;globalThis.XMLHttpRequest=undefined;globalThis.WebSocket=undefined;globalThis.importScripts=undefined;");
        engine.Execute(request.Source, $"lumen-plugin://{pluginId}/worker.js");
    }

    private void Dispatch(PluginWorkerRequest request, bool optional)
    {
        if (engine is null) throw new InvalidOperationException("Plugin worker is not loaded.");
        if (request.Context is { } context && context.Permissions.Any(permission => !allowedPermissions.Contains(permission)))
            throw new InvalidDataException("Plugin worker request exceeds its granted permissions.");
        var hasHandler = engine.GetValue("onmessage").IsCallable() || (int)engine.Evaluate("__lumenListeners.length").AsNumber() > 0;
        if (!hasHandler && optional) return;
        if (!hasHandler) throw new InvalidOperationException("Plugin worker did not install an onmessage handler.");
        var payload = PluginWorkerCodec.EncodePayload(new
        {
            type = request.Type == PluginWorkerRequestKind.RunCommand ? "run-command" : request.Type.ToString().ToLowerInvariant(),
            id = request.CommandId, context = request.Context
        });
        engine.Invoke("__lumenDispatch", payload);
    }

    private void ReceiveMessage(string json)
    {
        if (activeRequestId is null || emit is null) throw new InvalidOperationException("Plugin message arrived outside a request.");
        if (Encoding.UTF8.GetByteCount(json) > PluginWorkerProtocol.MaximumMessageBytes)
            throw new InvalidDataException("Plugin worker message exceeds the size limit.");
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 16 });
        var root = document.RootElement;
        var type = root.TryGetProperty("type", out var typeValue) ? typeValue.GetString() : null;
        var responseType = type switch
        {
            "register-command" => PluginWorkerResponseKind.RegisterCommand,
            "replace-document" => PluginWorkerResponseKind.ReplaceDocument,
            "notify" => PluginWorkerResponseKind.Notify,
            _ => throw new InvalidDataException("Plugin worker emitted an unknown message.")
        };
        if (responseType == PluginWorkerResponseKind.ReplaceDocument
            && !allowedPermissions.Contains(PluginPermission.DocumentEdit))
            throw new InvalidDataException("Plugin was not granted document-edit permission.");
        string? Text(string name) => root.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        emit(new PluginWorkerResponse(PluginWorkerProtocol.Version, responseType, activeRequestId,
            Text("id"), Text("title"), Text("text")));
    }

    private static string Bound(string value, int maximum) => value.Length <= maximum ? value : value[..maximum];
}
