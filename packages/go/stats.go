package cronwatch

import (
	"math"
	"sort"
)

// percentile is stats.ts percentile: the nearest-rank value, with the rank
// worked out in the same floating point steps as JavaScript's, so a Go and
// a Node process pick the same run. ok is false for no values.
func percentile(values []float64, p float64) (float64, bool) {
	if len(values) == 0 {
		return 0, false
	}
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	n := len(sorted)
	index := int(math.Min(float64(n-1), math.Max(0, math.Ceil((p/100)*float64(n))-1)))
	return sorted[index], true
}

// median is stats.ts median: the middle value, or the mean of the two in
// the middle.
func median(values []float64) (float64, bool) {
	if len(values) == 0 {
		return 0, false
	}
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 0 {
		return (sorted[mid-1] + sorted[mid]) / 2, true
	}
	return sorted[mid], true
}
