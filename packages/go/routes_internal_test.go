package cronwatch

import "testing"

func TestOnlyAnOriginThatReadsAsOneIsLoopback(t *testing.T) {
	for _, yes := range []string{"http://localhost", "http://localhost:3000", "http://app.localhost", "https://127.0.0.1", "http://127.8.9.10:1", "http://[::1]:3000"} {
		if !isLoopbackOrigin(yes) {
			t.Errorf("%s should be loopback", yes)
		}
	}
	for _, no := range []string{
		"http://localhost.example", "http://128.0.0.1", "http://127.0.0.256", "http://10.0.0.5:8080", "http://[::2]",
		// A Host header that is not a host (the Rust audit).
		"http://evil.example/.localhost", "http://localhost:1@evil.example", "http://evil.example?.localhost",
		"http://evil.example#.localhost", "http://localhost:1@evil.example:80",
	} {
		if isLoopbackOrigin(no) {
			t.Errorf("%s should not be loopback", no)
		}
	}
}
