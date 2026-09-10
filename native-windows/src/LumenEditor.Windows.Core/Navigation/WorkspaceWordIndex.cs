using System.Text.RegularExpressions;
using LumenEditor.Windows.Core.Documents;

namespace LumenEditor.Windows.Core.Navigation;

public static class WorkspaceWordIndex
{
    public const int MaximumWords = 20_000;
    public const int MaximumFiles = 20_000;
    public const int MaximumFileBytes = 2 * 1024 * 1024;
    private static readonly Regex Words = new(
        @"[A-Za-z_$][A-Za-z0-9_$]{1,80}", RegexOptions.CultureInvariant,
        TimeSpan.FromMilliseconds(100));

    public static async Task<IReadOnlyList<string>> BuildAsync(
        IEnumerable<string> files, CancellationToken cancellationToken = default)
    {
        var words = new HashSet<string>(StringComparer.Ordinal);
        foreach (var path in files.Take(MaximumFiles))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var info = new FileInfo(path);
                if (!info.Exists || info.Length > MaximumFileBytes) continue;
                var bytes = await File.ReadAllBytesAsync(path, cancellationToken);
                var encoding = TextFileCodec.DetectEncoding(bytes);
                var utf16 = encoding is TextEncodingKind.Utf16Le or TextEncodingKind.Utf16Be
                    or TextEncodingKind.Utf16LeNoBom or TextEncodingKind.Utf16BeNoBom;
                if (TextFileCodec.LooksBinary(bytes, utf16)) continue;
                var decoded = TextFileCodec.DecodeAuto(bytes);
                if (decoded.EncodingIssue == TextEncodingIssue.InvalidBytes) continue;
                foreach (Match match in Words.Matches(decoded.Content))
                {
                    words.Add(match.Value);
                    if (words.Count >= MaximumWords) break;
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException
                or RegexMatchTimeoutException) { }
            if (words.Count >= MaximumWords) break;
        }
        return words.Order(StringComparer.OrdinalIgnoreCase).ToArray();
    }
}
