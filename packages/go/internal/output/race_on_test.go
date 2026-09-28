//go:build race

package output

// The race detector slows the matcher down many times over, so the timing
// tests widen their bounds under it.
const raceEnabled = true
