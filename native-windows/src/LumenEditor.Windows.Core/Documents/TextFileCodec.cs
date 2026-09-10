using System.Text;

namespace LumenEditor.Windows.Core.Documents;

public enum TextEncodingKind
{
    Utf8,
    Utf8Bom,
    Utf16Le,
    Utf16Be,
    Utf16LeNoBom,
    Utf16BeNoBom,
    Gb18030,
    Gbk,
    Big5,
    ShiftJis,
    Windows1252,
    Iso88591
}

public enum LineEnding { Lf, CrLf, Cr }

public enum TextEncodingIssue { None, InvalidBytes, Uncertain }

public sealed record DecodedTextFile(
    string Content,
    TextEncodingKind Encoding,
    LineEnding LineEnding,
    TextEncodingIssue EncodingIssue);

/// <summary>Windows counterpart of the Electron/native macOS bounded text decoder.</summary>
public static class TextFileCodec
{
    private static readonly byte[] Utf8Bom = [0xEF, 0xBB, 0xBF];
    private static readonly byte[] Utf16LeBom = [0xFF, 0xFE];
    private static readonly byte[] Utf16BeBom = [0xFE, 0xFF];

    static TextFileCodec()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    public static bool LooksBinary(ReadOnlySpan<byte> bytes, bool isUtf16 = false)
    {
        if (isUtf16) return false;
        return bytes[..Math.Min(bytes.Length, 8192)].Contains((byte)0);
    }

    public static DecodedTextFile DecodeAuto(ReadOnlySpan<byte> bytes)
    {
        var detected = DetectEncoding(bytes);
        var issue = detected is TextEncodingKind.Utf16LeNoBom or TextEncodingKind.Utf16BeNoBom
            ? TextEncodingIssue.Uncertain
            : TextEncodingIssue.None;
        try
        {
            var content = DecodeStrict(bytes, detected);
            return new(NormalizeLineEndings(content), detected, DetectLineEnding(content), issue);
        }
        catch (DecoderFallbackException) when (detected is TextEncodingKind.Utf8 or TextEncodingKind.Utf8Bom)
        {
            var content = new UTF8Encoding(false, false).GetString(bytes);
            return new(NormalizeLineEndings(content), TextEncodingKind.Utf8, DetectLineEnding(content), TextEncodingIssue.InvalidBytes);
        }
    }

    public static DecodedTextFile Decode(ReadOnlySpan<byte> bytes, TextEncodingKind encoding)
    {
        var content = DecodeStrict(bytes, encoding);
        return new(NormalizeLineEndings(content), encoding, DetectLineEnding(content), TextEncodingIssue.None);
    }

    public static TextEncodingKind DetectEncoding(ReadOnlySpan<byte> bytes)
    {
        if (bytes.StartsWith(Utf8Bom)) return TextEncodingKind.Utf8Bom;
        if (bytes.StartsWith(Utf16LeBom)) return TextEncodingKind.Utf16Le;
        if (bytes.StartsWith(Utf16BeBom)) return TextEncodingKind.Utf16Be;
        if (bytes.Length >= 8)
        {
            var evenNuls = 0;
            var oddNuls = 0;
            for (var index = 0; index < bytes.Length; index++)
            {
                if (bytes[index] != 0) continue;
                if (index % 2 == 0) evenNuls++; else oddNuls++;
            }
            var pairs = bytes.Length / 2;
            if (oddNuls * 4 >= pairs * 3 && evenNuls * 4 <= pairs) return TextEncodingKind.Utf16LeNoBom;
            if (evenNuls * 4 >= pairs * 3 && oddNuls * 4 <= pairs) return TextEncodingKind.Utf16BeNoBom;
        }
        return TextEncodingKind.Utf8;
    }

    public static LineEnding DetectLineEnding(string content)
    {
        var lf = content.IndexOf('\n');
        if (lf >= 0) return lf > 0 && content[lf - 1] == '\r' ? LineEnding.CrLf : LineEnding.Lf;
        return content.IndexOf('\r') >= 0 ? LineEnding.Cr : LineEnding.Lf;
    }

    public static string NormalizeLineEndings(string content) => content.Replace("\r\n", "\n").Replace('\r', '\n');

    private static string DecodeStrict(ReadOnlySpan<byte> bytes, TextEncodingKind kind)
    {
        var encoding = EncodingFor(kind, throwOnInvalidBytes: true);
        var offset = kind switch
        {
            TextEncodingKind.Utf8Bom => Utf8Bom.Length,
            TextEncodingKind.Utf16Le or TextEncodingKind.Utf16Be => 2,
            _ => 0
        };
        if (kind is TextEncodingKind.Utf16Le or TextEncodingKind.Utf16Be or TextEncodingKind.Utf16LeNoBom or TextEncodingKind.Utf16BeNoBom)
        {
            if ((bytes.Length - offset) % 2 != 0) throw new DecoderFallbackException("UTF-16 byte length is odd.");
        }
        return encoding.GetString(bytes[offset..]);
    }

    private static Encoding EncodingFor(TextEncodingKind kind, bool throwOnInvalidBytes)
    {
        return kind switch
        {
            TextEncodingKind.Utf8 or TextEncodingKind.Utf8Bom => new UTF8Encoding(false, throwOnInvalidBytes),
            TextEncodingKind.Utf16Le or TextEncodingKind.Utf16LeNoBom => new UnicodeEncoding(false, false, throwOnInvalidBytes),
            TextEncodingKind.Utf16Be or TextEncodingKind.Utf16BeNoBom => new UnicodeEncoding(true, false, throwOnInvalidBytes),
            TextEncodingKind.Gb18030 => Encoding.GetEncoding(54936, EncoderFallback.ExceptionFallback, throwOnInvalidBytes ? DecoderFallback.ExceptionFallback : DecoderFallback.ReplacementFallback),
            TextEncodingKind.Gbk => Encoding.GetEncoding(936, EncoderFallback.ExceptionFallback, throwOnInvalidBytes ? DecoderFallback.ExceptionFallback : DecoderFallback.ReplacementFallback),
            TextEncodingKind.Big5 => Encoding.GetEncoding(950, EncoderFallback.ExceptionFallback, throwOnInvalidBytes ? DecoderFallback.ExceptionFallback : DecoderFallback.ReplacementFallback),
            TextEncodingKind.ShiftJis => Encoding.GetEncoding(932, EncoderFallback.ExceptionFallback, throwOnInvalidBytes ? DecoderFallback.ExceptionFallback : DecoderFallback.ReplacementFallback),
            TextEncodingKind.Windows1252 => Encoding.GetEncoding(1252, EncoderFallback.ExceptionFallback, throwOnInvalidBytes ? DecoderFallback.ExceptionFallback : DecoderFallback.ReplacementFallback),
            TextEncodingKind.Iso88591 => Encoding.Latin1,
            _ => throw new ArgumentOutOfRangeException(nameof(kind))
        };
    }
}
