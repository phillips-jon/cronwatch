package bridge_test

import (
	"errors"
	"strings"
	"testing"
	"time"

	"cronwatch.dev/go/bridge"
)

// daily is a scheduler that runs at hour:00 UTC every step days from the epoch.
func daily(hour, step int) bridge.Runs {
	return func(start int64, end *int64) ([]int64, error) {
		at := func(day int64) int64 { return day*86_400_000 + int64(hour)*3_600_000 }
		day := start / 86_400_000
		for at(day) > start || day%int64(step) != 0 {
			day--
		}
		out := []int64{at(day)}
		for day += int64(step); ; day += int64(step) {
			out = append(out, at(day))
			if (end == nil && len(out) > bridge.SampleRuns) || (end != nil && at(day) > *end) {
				return out, nil
			}
		}
	}
}

func TestCheckFires(t *testing.T) {
	now := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC).UnixMilli()
	if err := bridge.CheckFires(daily(2, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now); err != nil {
		t.Errorf("the same times: %v", err)
	}
	err := bridge.CheckFires(daily(2, 2), "0 2 * * *", "UTC", "cronwatch: x", "a scheduler", true, now)
	if err == nil || !strings.Contains(err.Error(), `cronwatch: x is "0 2 * * *" in UTC, but after a run at`) || !strings.Contains(err.Error(), "a scheduler runs it next at") {
		t.Errorf("every other day: %v", err)
	}
	var refused *bridge.ScheduleError
	if !errors.As(err, &refused) {
		t.Errorf("not a ScheduleError: %T", err)
	}
	if err := bridge.CheckFires(daily(3, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now); err == nil {
		t.Error("an hour apart was taken")
	}
	never := func(int64, *int64) ([]int64, error) { return nil, bridge.NeverFires("no fire time") }
	if err := bridge.CheckFires(never, "0 2 * * *", "UTC", "x", "a scheduler", true, now); err == nil || !strings.Contains(err.Error(), "which never fires: no fire time") {
		t.Errorf("never: %v", err)
	}
	if err := bridge.CheckFires(daily(2, 1), "not a cron", "UTC", "x", "a scheduler", true, now); err == nil || !strings.Contains(err.Error(), "which CronWatch cannot read") {
		t.Errorf("unreadable: %v", err)
	}
}
