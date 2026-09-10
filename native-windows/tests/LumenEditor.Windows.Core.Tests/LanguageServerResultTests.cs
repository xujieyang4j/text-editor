using System.Text.Json;
using LumenEditor.Windows.Core.Language;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class LanguageServerResultTests
{
    [Fact]
    public void Hover_FlattensMarkedContent()
    {
        using var json = JsonDocument.Parse("""{"contents":["first",{"kind":"markdown","value":"second"}]}""");
        Assert.Equal("first\n\nsecond", LanguageServerResults.ParseHover(json.RootElement));
    }

    [Fact]
    public void Locations_RejectFilesOutsideWorkspace()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenLsp", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var inside = new Uri(Path.Combine(root, "inside.cs")).AbsoluteUri;
            var outside = new Uri(Path.Combine(Path.GetTempPath(), "outside.cs")).AbsoluteUri;
            using var json = JsonDocument.Parse(JsonSerializer.Serialize(new object[]
            {
                new { uri = inside, range = new { start = new { line = 2, character = 3 }, end = new { line = 2, character = 4 } } },
                new { uri = outside, range = new { start = new { line = 0, character = 0 }, end = new { line = 0, character = 1 } } }
            }));

            var result = LanguageServerResults.ParseLocations(json.RootElement, root);
            Assert.Equal(new LanguageLocation(Path.Combine(root, "inside.cs"), 2, 3), Assert.Single(result));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void Rename_ParsesWorkspaceChanges()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenLsp", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var uri = new Uri(Path.Combine(root, "file.cs")).AbsoluteUri;
            using var json = JsonDocument.Parse(JsonSerializer.Serialize(new
            {
                changes = new Dictionary<string, object[]>
                {
                    [uri] = [new
                    {
                        range = new { start = new { line = 1, character = 2 }, end = new { line = 1, character = 5 } },
                        newText = "next"
                    }]
                }
            }));
            var result = LanguageServerResults.ParseRenameEdits(json.RootElement, root);
            Assert.Equal(new LanguageRenameEdit(Path.Combine(root, "file.cs"), 1, 2, 1, 5, "next"), Assert.Single(result));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void Diagnostics_AreBoundedAndRootConfined()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenLsp", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var uri = new Uri(Path.Combine(root, "file.cs")).AbsoluteUri;
            using var json = JsonDocument.Parse(JsonSerializer.Serialize(new
            {
                method = "textDocument/publishDiagnostics",
                @params = new
                {
                    uri,
                    diagnostics = new[] { new
                    {
                        range = new { start = new { line = 4, character = 2 }, end = new { line = 4, character = 6 } },
                        severity = 2,
                        message = "warning text"
                    } }
                }
            }));
            var diagnostic = Assert.Single(LanguageServerResults.ParseDiagnostics(json.RootElement, root));
            Assert.Equal("warning", diagnostic.Severity);
            Assert.Equal(4, diagnostic.Line);
            Assert.Equal("warning text", diagnostic.Message);
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void Diagnostics_PreserveVersionAndEmptySnapshotForClearing()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenLsp", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "file.cs");
            using var json = JsonDocument.Parse(JsonSerializer.Serialize(new
            {
                method = "textDocument/publishDiagnostics",
                @params = new { uri = new Uri(path).AbsoluteUri, version = 7, diagnostics = Array.Empty<object>() }
            }));
            var snapshot = Assert.IsType<LanguageDiagnosticSnapshot>(
                LanguageServerResults.ParseDiagnosticSnapshot(json.RootElement, root));
            Assert.Equal(path, snapshot.Path);
            Assert.Equal(7, snapshot.Version);
            Assert.Empty(snapshot.Diagnostics);
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void FormattingEdits_AreParsedAndAppliedAtomicallyInUtf16Coordinates()
    {
        using var json = JsonDocument.Parse(JsonSerializer.Serialize(new object[]
        {
            new
            {
                range = new { start = new { line = 0, character = 1 }, end = new { line = 0, character = 3 } },
                newText = "X"
            },
            new
            {
                range = new { start = new { line = 1, character = 0 }, end = new { line = 1, character = 1 } },
                newText = "B\r\nC"
            }
        }));
        var edits = LanguageServerResults.ParseFormattingEdits(json.RootElement);
        Assert.Equal("aXz\nB\nCar", LanguageServerResults.ApplyFormattingEdits("a😀z\nbar", edits));
    }

    [Fact]
    public void FormattingEdits_RejectOverlapsAndSurrogateSplits()
    {
        Assert.Throws<InvalidDataException>(() => LanguageServerResults.ApplyFormattingEdits(
            "abcdef",
            [new(0, 1, 0, 4, "x"), new(0, 3, 0, 5, "y")]));
        Assert.Throws<InvalidDataException>(() => LanguageServerResults.ApplyFormattingEdits(
            "a😀z", [new(0, 2, 0, 2, "x")]));
    }
}
