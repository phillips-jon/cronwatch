using System;
using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Cronwatch.Tests.Posting;

/// <summary>
/// A certificate authority and server certificates made at run time, so no key is committed: a
/// root the tests' transport trusts, and leaves it signs for the names and addresses a test asks.
/// </summary>
internal sealed class TestCertificates : IDisposable
{
    private readonly ECDsa _rootKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);

    public TestCertificates(string name = "CronWatch test root")
    {
        var request = new CertificateRequest("CN=" + name, _rootKey, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        Root = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(30));
    }

    /// <summary>The root, without its key, as a client trusts it.</summary>
    public X509Certificate2 Root { get; }

    /// <summary>A server certificate for these DNS names and addresses, with its key, signed by the root.</summary>
    public X509Certificate2 Leaf(string[] names, IPAddress[] addresses)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=" + (names.Length > 0 ? names[0] : addresses[0].ToString()), key, HashAlgorithmName.SHA256);
        var san = new SubjectAlternativeNameBuilder();
        foreach (string n in names)
        {
            san.AddDnsName(n);
        }
        foreach (IPAddress a in addresses)
        {
            san.AddIpAddress(a);
        }
        request.CertificateExtensions.Add(san.Build());
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, false));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid("1.3.6.1.5.5.7.3.1")], false));
        var serial = new byte[8];
        RandomNumberGenerator.Fill(serial);
        serial[0] &= 0x7f;
        using X509Certificate2 signed = request.Create(Root.SubjectName, X509SignatureGenerator.CreateForECDsa(_rootKey), DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(30), serial);
        using X509Certificate2 withKey = signed.CopyWithPrivateKey(key);
        // Through PKCS#12 and back, so every platform's TLS (macOS's and Windows' included) can use
        // the key from a certificate made in memory.
        return X509CertificateLoader.LoadPkcs12(withKey.Export(X509ContentType.Pkcs12), null);
    }

    public void Dispose()
    {
        Root.Dispose();
        _rootKey.Dispose();
    }
}
