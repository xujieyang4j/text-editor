namespace LumenEditor.Windows.Core;

public enum CommandExecutionState { Executed, Unsupported, Disabled, Failed }

public sealed record CommandExecutionResult(CommandExecutionState State, string? Message = null)
{
    public static readonly CommandExecutionResult Executed = new(CommandExecutionState.Executed);
}

/// <summary>Typed dispatcher shared by Windows menus, keyboard accelerators and a future palette.</summary>
public sealed class WindowsCommandRouter
{
    private readonly Dictionary<string, Func<CancellationToken, Task<CommandExecutionResult>>> handlers =
        new(StringComparer.Ordinal);
    public IReadOnlyList<string> RegisteredCommandIds => handlers.Keys.Order(StringComparer.Ordinal).ToList();
    public bool IsRegistered(string commandId) => handlers.ContainsKey(commandId);

    public bool Register(string commandId, Func<CancellationToken, Task<CommandExecutionResult>> handler)
    {
        if (!WindowsCommandCatalog.All.Contains(commandId, StringComparer.Ordinal)) return false;
        return handlers.TryAdd(commandId, handler);
    }

    public async Task<CommandExecutionResult> ExecuteAsync(string commandId, CancellationToken cancellationToken = default)
    {
        if (!WindowsCommandCatalog.All.Contains(commandId, StringComparer.Ordinal))
        {
            return new(CommandExecutionState.Unsupported, "Unknown command.");
        }
        if (!handlers.TryGetValue(commandId, out var handler))
        {
            return new(CommandExecutionState.Unsupported, "This command is not implemented in the current Windows native phase.");
        }
        try
        {
            return await handler(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new(CommandExecutionState.Disabled, "The command was cancelled.");
        }
        catch (Exception error)
        {
            return new(CommandExecutionState.Failed, error.Message);
        }
    }
}
