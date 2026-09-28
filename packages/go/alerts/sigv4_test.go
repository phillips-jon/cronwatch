package alerts

import (
	"strings"
	"testing"
)

// Cases from the AWS Signature Version 4 test suite (aws-sig-v4-test-suite,
// as republished in @saibotsivad/aws-sig-v4-test-suite), as the SDK's
// sigv4.test.ts has them: service "service", region us-east-1, the
// example credentials, 2015-08-30T12:36:00Z.
func TestSigV4MatchesTheAWSTestSuite(t *testing.T) {
	creds := sigV4Credentials{accessKeyID: "AKIDEXAMPLE", secretAccessKey: strings.Join([]string{"wJalrXUtnFEMI", "K7MDENG+bPxRfiCYEXAMPLEKEY"}, "/")}
	const now = 1440938160000
	const scope = "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request"
	token := "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA=="
	cases := []struct {
		name, method, url string
		headers           []header
		sessionToken      string
		authz             string
	}{
		{"get-vanilla", "GET", "https://example.amazonaws.com/", nil, "",
			"AWS4-HMAC-SHA256 " + scope + ", SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"},
		{"post-vanilla", "POST", "https://example.amazonaws.com/", nil, "",
			"AWS4-HMAC-SHA256 " + scope + ", SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"},
		{"get-vanilla-query-order-key-case", "GET", "https://example.amazonaws.com/?Param2=value2&Param1=value1", nil, "",
			"AWS4-HMAC-SHA256 " + scope + ", SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"},
		{"post-header-value-case", "POST", "https://example.amazonaws.com/", []header{{Name: "My-Header1", Value: "VALUE1"}}, "",
			"AWS4-HMAC-SHA256 " + scope + ", SignedHeaders=host;my-header1;x-amz-date, Signature=cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d"},
		{"post-sts-header-before", "POST", "https://example.amazonaws.com/", nil, token,
			"AWS4-HMAC-SHA256 " + scope + ", SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead"},
	}
	for _, c := range cases {
		cr := creds
		cr.sessionToken = c.sessionToken
		headers, err := signV4(sigV4Request{method: c.method, url: c.url, headers: c.headers, region: "us-east-1", service: "service", now: now}, cr)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]string{}
		for _, h := range headers {
			got[h.Name] = h.Value
		}
		if got["authorization"] != c.authz {
			t.Errorf("%s:\n got %s\nwant %s", c.name, got["authorization"], c.authz)
		}
		if got["x-amz-date"] != "20150830T123600Z" {
			t.Errorf("%s: x-amz-date %s", c.name, got["x-amz-date"])
		}
		if _, ok := got["host"]; ok {
			t.Errorf("%s: host is returned; the HTTP client sets it", c.name)
		}
		if c.sessionToken != "" && got["x-amz-security-token"] != c.sessionToken {
			t.Errorf("%s: no session token", c.name)
		}
	}
}
