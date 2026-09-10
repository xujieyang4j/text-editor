using System.Security.Cryptography;
using System.Text;

namespace LumenEditor.Windows.Core.Documents;

public enum FileWriteFailure { None, Missing, RevisionConflict, NotARegularFile, IoFailure, CannotRepresent }

public sealed record FileWriteResult(
    bool Saved, string? Revision, FileWriteFailure Failure = FileWriteFailure.None, string? Message = null);

/// <summary>Revision-checked temp-file replacement for Windows document saves.</summary>
public sealed class FileWriteService
{
    public async Task<FileWriteResult> SaveAsync(
        string path, string content, TextEncodingKind encoding, LineEnding lineEnding,
        string? expectedRevision, CancellationToken cancellationToken = default)
    {
        var fullPath = Path.GetFullPath(path);
        try
        {
            if (Directory.Exists(fullPath))
            {
                return new(false, null, FileWriteFailure.NotARegularFile, "The save target is not a regular file.");
            }
            var existedBeforeWrite = File.Exists(fullPath);
            var actualRevision = existedBeforeWrite ? await RevisionAsync(fullPath, cancellationToken) : null;
            if (!StringComparer.Ordinal.Equals(expectedRevision, actualRevision))
            {
                return new(false, actualRevision, FileWriteFailure.RevisionConflict,
                    "The file changed on disk before it could be saved.");
            }

            var data = Encode(content, encoding, lineEnding);
            var directory = Path.GetDirectoryName(fullPath);
            if (String.IsNullOrWhiteSpace(directory))
            {
                return new(false, null, FileWriteFailure.IoFailure, "The save target has no directory.");
            }
            Directory.CreateDirectory(directory);
            var temporary = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
            try
            {
                await File.WriteAllBytesAsync(temporary, data, cancellationToken);
                var revisionBeforeReplace = File.Exists(fullPath)
                    ? await RevisionAsync(fullPath, cancellationToken)
                    : null;
                if (!StringComparer.Ordinal.Equals(expectedRevision, revisionBeforeReplace))
                {
                    return new(false, revisionBeforeReplace, FileWriteFailure.RevisionConflict,
                        "The file changed while its replacement was being prepared.");
                }
                if (File.Exists(fullPath))
                {
                    File.Replace(temporary, fullPath, destinationBackupFileName: null, ignoreMetadataErrors: true);
                }
                else
                {
                    File.Move(temporary, fullPath);
                }
                temporary = string.Empty;
                return new(true, ComputeRevision(data));
            }
            finally
            {
                if (!String.IsNullOrEmpty(temporary)) File.Delete(temporary);
            }
        }
        catch (EncoderFallbackException error)
        {
            return new(false, null, FileWriteFailure.CannotRepresent, error.Message);
        }
        catch (IOException error)
        {
            return new(false, null, FileWriteFailure.IoFailure, error.Message);
        }
        catch (UnauthorizedAccessException error)
        {
            return new(false, null, FileWriteFailure.IoFailure, error.Message);
        }
    }

    public static async Task<string?> RevisionAsync(string path, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path)) return null;
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, true);
        var hash = await SHA256.HashDataAsync(stream, cancellationToken);
        return "sha256:" + Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static byte[] Encode(string content, TextEncodingKind kind, LineEnding lineEnding)
    {
        var normalized = lineEnding switch
        {
            LineEnding.CrLf => content.Replace("\r\n", "\n").Replace('\r', '\n').Replace("\n", "\r\n"),
            LineEnding.Cr => content.Replace("\r\n", "\n").Replace('\r', '\n').Replace("\n", "\r"),
            _ => content.Replace("\r\n", "\n").Replace('\r', '\n')
        };
        return kind switch
        {
            TextEncodingKind.Utf8 => new UTF8Encoding(false, true).GetBytes(normalized),
            TextEncodingKind.Utf8Bom => [.. new byte[] { 0xEF, 0xBB, 0xBF }, .. new UTF8Encoding(false, true).GetBytes(normalized)],
            TextEncodingKind.Utf16Le => [.. new byte[] { 0xFF, 0xFE }, .. new UnicodeEncoding(false, false, true).GetBytes(normalized)],
            TextEncodingKind.Utf16LeNoBom => new UnicodeEncoding(false, false, true).GetBytes(normalized),
            TextEncodingKind.Utf16Be => [.. new byte[] { 0xFE, 0xFF }, .. new UnicodeEncoding(true, false, true).GetBytes(normalized)],
            TextEncodingKind.Utf16BeNoBom => new UnicodeEncoding(true, false, true).GetBytes(normalized),
            TextEncodingKind.Windows1252 => Encoding.GetEncoding(1252, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetBytes(normalized),
            TextEncodingKind.Iso88591 => Encoding.Latin1.GetBytes(normalized),
            TextEncodingKind.Gb18030 => Encoding.GetEncoding(54936, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetBytes(normalized),
            TextEncodingKind.Gbk => Encoding.GetEncoding(936, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetBytes(normalized),
            TextEncodingKind.Big5 => Encoding.GetEncoding(950, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetBytes(normalized),
            TextEncodingKind.ShiftJis => Encoding.GetEncoding(932, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetBytes(normalized),
            _ => throw new ArgumentOutOfRangeException(nameof(kind))
        };
    }

    public static string ComputeRevision(ReadOnlySpan<byte> data) =>
        "sha256:" + Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
}
