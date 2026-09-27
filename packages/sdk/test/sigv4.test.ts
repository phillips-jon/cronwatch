import assert from "node:assert/strict";
import { test } from "node:test";
import { signV4 } from "../src/alerts/sigv4.js";

// Cases from the AWS Signature Version 4 test suite (aws-sig-v4-test-suite,
// as republished in @saibotsivad/aws-sig-v4-test-suite): service "service",
// region us-east-1, the example credentials, 2015-08-30T12:36:00Z.
const credentials = { accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" };
const now = Date.UTC(2015, 7, 30, 12, 36, 0);
const scope = "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request";
const STS_TOKEN =
  "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA==";

const cases: { name: string; method: string; url: string; headers: Record<string, string>; body: string; sessionToken?: string; authz: string }[] = [
  {
    name: "get-vanilla",
    method: "GET", url: "https://example.amazonaws.com/", headers: {}, body: "",
    authz: `AWS4-HMAC-SHA256 ${scope}, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31`,
  },
  {
    name: "post-vanilla",
    method: "POST", url: "https://example.amazonaws.com/", headers: {}, body: "",
    authz: `AWS4-HMAC-SHA256 ${scope}, SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b`,
  },
  {
    name: "get-vanilla-query-order-key-case",
    method: "GET", url: "https://example.amazonaws.com/?Param2=value2&Param1=value1", headers: {}, body: "",
    authz: `AWS4-HMAC-SHA256 ${scope}, SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500`,
  },
  {
    name: "post-header-value-case",
    method: "POST", url: "https://example.amazonaws.com/", headers: { "My-Header1": "VALUE1" }, body: "",
    authz: `AWS4-HMAC-SHA256 ${scope}, SignedHeaders=host;my-header1;x-amz-date, Signature=cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d`,
  },
  {
    name: "post-sts-header-before",
    method: "POST", url: "https://example.amazonaws.com/", headers: {}, body: "", sessionToken: STS_TOKEN,
    authz: `AWS4-HMAC-SHA256 ${scope}, SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead`,
  },
];

for (const c of cases) {
  test(`sigv4 matches the AWS test suite: ${c.name}`, async () => {
    const headers = await signV4(
      { method: c.method, url: c.url, headers: c.headers, body: c.body, region: "us-east-1", service: "service", now },
      { ...credentials, ...(c.sessionToken ? { sessionToken: c.sessionToken } : {}) },
    );
    assert.equal(headers.authorization, c.authz);
    assert.equal(headers["x-amz-date"], "20150830T123600Z");
    assert.equal(headers.host, undefined, "fetch sets Host itself");
    if (c.sessionToken) assert.equal(headers["x-amz-security-token"], c.sessionToken);
  });
}
