package dev.cronwatch.alerts;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.util.List;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;

/**
 * A certificate made at run time with the JDK's own {@code keytool}, so no key is committed: a
 * server's TLS context over it, and a client's that trusts it alone.
 */
final class Certificates {
  private static final char[] PASSWORD = "changeit".toCharArray();

  private final KeyStore store;

  private Certificates(KeyStore store) {
    this.store = store;
  }

  /** A self-signed certificate for {@code san} ({@code ip:127.0.0.1,dns:localhost}, say). */
  static Certificates make(Path dir, String san) throws Exception {
    Path file = dir.resolve("cert-" + System.nanoTime() + ".p12");
    Path keytool = Path.of(System.getProperty("java.home"), "bin", "keytool");
    Process p =
        new ProcessBuilder(
                List.of(
                    keytool.toString(),
                    "-genkeypair",
                    "-alias",
                    "server",
                    "-keyalg",
                    "EC",
                    "-groupname",
                    "secp256r1",
                    "-dname",
                    "CN=cronwatch test",
                    "-ext",
                    "SAN=" + san,
                    "-validity",
                    "2",
                    "-storetype",
                    "PKCS12",
                    "-keystore",
                    file.toString(),
                    "-storepass",
                    new String(PASSWORD),
                    "-keypass",
                    new String(PASSWORD)))
            .redirectErrorStream(true)
            .start();
    String out =
        new String(p.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
    if (!p.waitFor(60, TimeUnit.SECONDS) || p.exitValue() != 0) {
      throw new IOException("keytool failed: " + out);
    }
    KeyStore ks = KeyStore.getInstance("PKCS12");
    try (InputStream in = Files.newInputStream(file)) {
      ks.load(in, PASSWORD);
    }
    return new Certificates(ks);
  }

  /** A server's context presenting the certificate. */
  SSLContext server() throws GeneralSecurityException {
    KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
    kmf.init(store, PASSWORD);
    SSLContext c = SSLContext.getInstance("TLS");
    c.init(kmf.getKeyManagers(), null, null);
    return c;
  }

  /** A client's context that trusts this certificate and nothing else. */
  SSLContext trusting() throws GeneralSecurityException, IOException {
    Certificate cert = store.getCertificate("server");
    KeyStore trust = KeyStore.getInstance("PKCS12");
    trust.load(null, null);
    trust.setCertificateEntry("server", cert);
    TrustManagerFactory tmf =
        TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
    tmf.init(trust);
    SSLContext c = SSLContext.getInstance("TLS");
    c.init(null, tmf.getTrustManagers(), null);
    return c;
  }
}
