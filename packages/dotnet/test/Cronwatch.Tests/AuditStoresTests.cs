using System.Text;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>What the audit's stores and outbound pass checked in redaction without finding a bug, kept so it stays so.</summary>
public class AuditStoresTests
{
    /// <summary>A PEM block of some lines, its body a repeated filler rather than a key.</summary>
    private static string Pem(int lines)
    {
        var b = new StringBuilder("-----BEGIN " + "PRIVATE KEY-----\n");
        for (int i = 0; i < lines; i++)
        {
            b.Append(new string('Q', 64)).Append('\n');
        }
        return b.Append("-----END " + "PRIVATE KEY-----").ToString();
    }

    /// <summary>
    /// A key of the size a 2048-bit one has, and one far past the engine's 512 frames in
    /// characters, is redacted whole: the body's alternation repeats without a frame per pass.
    /// </summary>
    [Theory]
    [InlineData(4)]
    [InlineData(26)]
    [InlineData(250)]
    public void A_whole_private_key_is_redacted(int lines)
    {
        string output = OutputText.RedactSecrets("key:\n" + Pem(lines) + "\ndone");
        Assert.Equal("key:\n[redacted]\ndone", output);
    }
}
