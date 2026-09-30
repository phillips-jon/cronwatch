//! AWS Signature Version 4, for the SES channel (`alerts/sigv4.ts`), so no
//! AWS SDK is needed. Spec:
//! <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html>.
//! Checked against the AWS SigV4 test suite (below).

use url::Url;

use super::shared::{hex, hmac_sha256, percent, sha256_hex};
use super::webhook::assign;
use crate::js;

/// Credentials that sign a request. The session token is for temporary
/// credentials (STS, an IAM role), sent and signed as `x-amz-security-token`.
pub(crate) struct Credentials {
    pub(crate) access_key_id: String,
    pub(crate) secret_access_key: String,
    pub(crate) session_token: String,
}

/// What is signed. Host is taken from the URL, and `x-amz-date` from `now`
/// (epoch milliseconds).
pub(crate) struct SigningRequest<'a> {
    pub(crate) method: &'a str,
    pub(crate) url: &'a str,
    pub(crate) headers: &'a [(&'a str, String)],
    pub(crate) body: &'a str,
    pub(crate) region: &'a str,
    pub(crate) service: &'a str,
    pub(crate) now: i64,
}

/// The headers to send: the given ones (names lowercased) plus
/// `x-amz-date`, the session token when there is one, and `authorization`.
/// Host is signed but not returned, because the HTTP client sets it.
pub(crate) fn sign(r: &SigningRequest<'_>, c: &Credentials) -> Result<Vec<(String, String)>, String> {
    let url = super::post::parse(r.url).map_err(|_| "cannot sign a request to an invalid URL".to_string())?;
    let iso = js::iso_string(r.now);
    let amz_date = format!("{}Z", iso[..19].replace(['-', ':'], ""));
    let day = &amz_date[..8];
    let mut headers: Vec<(String, String)> = Vec::new();
    for (name, value) in r.headers {
        assign(&mut headers, &name.to_lowercase(), value.clone());
    }
    assign(&mut headers, "x-amz-date", amz_date.clone());
    if !c.session_token.is_empty() {
        assign(&mut headers, "x-amz-security-token", c.session_token.clone());
    }

    let mut signed: Vec<(String, String)> = headers.iter().filter(|(n, _)| n != "host").cloned().collect();
    signed.push(("host".into(), host(&url)));
    signed.sort_by(|a, b| a.0.cmp(&b.0));
    let mut canonical_headers = String::new();
    for (n, v) in &signed {
        canonical_headers.push_str(&format!("{n}:{}\n", collapse(js::trim(v))));
    }
    let signed_headers = signed.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>().join(";");
    let canonical_request = [
        r.method.to_uppercase(),
        canonical_uri(url.path()),
        canonical_query(&url),
        canonical_headers,
        signed_headers.clone(),
        sha256_hex(r.body),
    ]
    .join("\n");
    let scope = format!("{day}/{}/{}/aws4_request", r.region, r.service);
    let string_to_sign = ["AWS4-HMAC-SHA256", &amz_date, &scope, &sha256_hex(&canonical_request)].join("\n");

    let mut key = hmac_sha256(format!("AWS4{}", c.secret_access_key).as_bytes(), day);
    key = hmac_sha256(&key, r.region);
    key = hmac_sha256(&key, r.service);
    key = hmac_sha256(&key, "aws4_request");
    let signature = hex(&hmac_sha256(&key, &string_to_sign));

    assign(
        &mut headers,
        "authorization",
        format!(
            "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed_headers}, Signature={signature}",
            c.access_key_id
        ),
    );
    Ok(headers)
}

/// `URL#host`: the host, and the port when it is not the scheme's own.
pub(crate) fn host(url: &Url) -> String {
    let h = url.host_str().unwrap_or("");
    match url.port() {
        Some(p) => format!("{h}:{p}"),
        None => h.to_string(),
    }
}

/// `.replace(/\s+/g, " ")` with JavaScript's `\s`.
fn collapse(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for c in text.chars() {
        if js::is_space(c) {
            space = true;
            continue;
        }
        if space {
            out.push(' ');
            space = false;
        }
        out.push(c);
    }
    if space {
        out.push(' ');
    }
    out
}

/// RFC 3986 encoding of every byte but the unreserved characters.
fn uri_encode(text: &str) -> String {
    percent(text, b"-_.~", false)
}

/// Each segment of the path, which is already encoded once, encoded again:
/// every AWS service but S3 expects that.
fn canonical_uri(path: &str) -> String {
    if path.is_empty() {
        return "/".into();
    }
    path.split('/').map(uri_encode).collect::<Vec<_>>().join("/")
}

/// The query as `URLSearchParams` reads it, each name and value encoded,
/// sorted by name and then value.
fn canonical_query(url: &Url) -> String {
    let mut pairs: Vec<(String, String)> = url.query_pairs().map(|(n, v)| (uri_encode(&n), uri_encode(&v))).collect();
    pairs.sort();
    pairs.iter().map(|(n, v)| format!("{n}={v}")).collect::<Vec<_>>().join("&")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Cases from the AWS Signature Version 4 test suite, as the SDK's
    /// sigv4.test.ts has them: service "service", region us-east-1, the
    /// example credentials, 2015-08-30T12:36:00Z.
    #[test]
    fn signatures_match_the_aws_test_suite() {
        let scope = "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request";
        let token = "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA==";
        let header = [("My-Header1", "VALUE1".to_string())];
        type Case<'a> = (&'a str, &'a str, &'a [(&'a str, String)], &'a str, &'a str, &'a str);
        let cases: [Case; 5] = [
            (
                "GET",
                "https://example.amazonaws.com/",
                &[],
                "",
                "host;x-amz-date",
                "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
            ),
            (
                "POST",
                "https://example.amazonaws.com/",
                &[],
                "",
                "host;x-amz-date",
                "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b",
            ),
            (
                "GET",
                "https://example.amazonaws.com/?Param2=value2&Param1=value1",
                &[],
                "",
                "host;x-amz-date",
                "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500",
            ),
            (
                "POST",
                "https://example.amazonaws.com/",
                &header,
                "",
                "host;my-header1;x-amz-date",
                "cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d",
            ),
            (
                "POST",
                "https://example.amazonaws.com/",
                &[],
                token,
                "host;x-amz-date;x-amz-security-token",
                "85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead",
            ),
        ];
        for (method, url, headers, session, signed, signature) in cases {
            let creds = Credentials {
                access_key_id: "AKIDEXAMPLE".into(),
                // Joined here, so the example key does not sit whole in the source.
                secret_access_key: ["wJalrXUtnFEMI", "K7MDENG+bPxRfiCYEXAMPLEKEY"].join("/"),
                session_token: session.into(),
            };
            let request = SigningRequest {
                method,
                url,
                headers,
                body: "",
                region: "us-east-1",
                service: "service",
                now: 1440938160000,
            };
            let got = sign(&request, &creds).unwrap();
            let get = |name: &str| got.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str());
            assert_eq!(
                get("authorization"),
                Some(format!("AWS4-HMAC-SHA256 {scope}, SignedHeaders={signed}, Signature={signature}").as_str()),
                "{method} {url}"
            );
            assert_eq!(get("x-amz-date"), Some("20150830T123600Z"));
            assert_eq!(get("host"), None, "host is returned; the HTTP client sets it");
            if !session.is_empty() {
                assert_eq!(get("x-amz-security-token"), Some(session));
            }
        }
    }
}
