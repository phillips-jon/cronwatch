package cronwatch

import "io"

// Hooks for the tests in package cronwatch_test.

// MaxRequestBody is the most of a request body the dashboard reads.
const MaxRequestBody = maxBody

// SwapStdout points the console channel's recoveries at w until the
// returned function puts them back.
func SwapStdout(w io.Writer) (restore func()) {
	before := Stdout
	Stdout = w
	return func() { Stdout = before }
}
