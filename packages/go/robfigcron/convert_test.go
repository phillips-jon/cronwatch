package robfigcron

import (
	"strings"
	"testing"
	"time"

	"github.com/robfig/cron/v3"
)

func mustLoad(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatal(err)
	}
	return loc
}

func TestConvertReadsEverySpecRobfigParses(t *testing.T) {
	utc := time.UTC
	london := mustLoad(t, "Europe/London")
	std := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)
	seconds := cron.NewParser(cron.SecondOptional | cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)
	cases := []struct {
		parser   cron.ScheduleParser
		spec     string
		loc      *time.Location
		schedule string
		zone     string
	}{
		{std, "0 2 * * *", utc, "0 2 * * *", "UTC"},
		{std, "*/15 * * * *", utc, "*/15 * * * *", "UTC"},
		{std, "5,10,15-20 9-17 * * mon-fri", utc, "5,10,15-20 9-17 * * 1-5", "UTC"},
		{std, "30 4 1,15 * *", utc, "30 4 1,15 * *", "UTC"},
		{std, "0 0 1 jan,jul *", utc, "0 0 1 1,7 *", "UTC"},
		{std, "@daily", utc, "0 0 * * *", "UTC"},
		{std, "@hourly", utc, "0 * * * *", "UTC"},
		{std, "@weekly", utc, "0 0 * * 0", "UTC"},
		{std, "@monthly", utc, "0 0 1 * *", "UTC"},
		{std, "@yearly", utc, "0 0 1 1 *", "UTC"},
		{std, "@every 90s", utc, "every 1m30s", ""},
		{std, "@every 2h", utc, "every 2h", ""},
		{std, "CRON_TZ=Asia/Tokyo 0 9 * * *", utc, "0 9 * * *", "Asia/Tokyo"},
		// A spec without a zone is read in the cron's Location.
		{std, "0 12 * * *", london, "0 12 * * *", "Europe/London"},
		// Both days restricted: either, as vixie cron and croner read them.
		{std, "0 0 1 * 1", utc, "0 0 1 * 1", "UTC"},
		// A step clears robfig/cron's "*" mark, so this is either day too.
		{std, "0 0 */2 * 1", utc, "0 0 */2 * 1", "UTC"},
		{std, "0 0 1-31 * 1", utc, "0 0 * * *", "UTC"},
		{seconds, "*/10 * * * * *", utc, "*/10 * * * * *", "UTC"},
		{seconds, "30 0 2 * * *", utc, "30 0 2 * * *", "UTC"},
		{seconds, "0 2 * * *", utc, "0 2 * * *", "UTC"},
	}
	for _, c := range cases {
		s, err := c.parser.Parse(c.spec)
		if err != nil {
			t.Fatalf("%s: %v", c.spec, err)
		}
		got, err := Convert(s, c.loc, "cronwatch: "+c.spec)
		if err != nil {
			t.Errorf("%s: %v", c.spec, err)
			continue
		}
		if got.Schedule != c.schedule || got.Timezone != c.zone {
			t.Errorf("%s: got %q in %q, want %q in %q", c.spec, got.Schedule, got.Timezone, c.schedule, c.zone)
		}
	}
}

func TestConvertRefusesWhatCannotMatch(t *testing.T) {
	newYork := mustLoad(t, "America/New_York")
	s, err := cron.ParseStandard("30 2 * * *")
	if err != nil {
		t.Fatal(err)
	}
	// robfig/cron skips 02:30 on the night clocks go forward, where croner
	// moves it to 03:30, so CronWatch would report a run missed.
	_, err = Convert(s, newYork, "cronwatch: robfig/cron entry 1 (jobs.Nightly)")
	if err == nil || !strings.Contains(err.Error(), "due at a time that does not exist in America/New_York") {
		t.Errorf("a time daylight saving skips: %v", err)
	}
	fixed := time.FixedZone("EST5", -5*3600)
	if _, err := Convert(s, fixed, "cronwatch: x"); err == nil || !strings.Contains(err.Error(), "is read in EST5, which is not an IANA timezone") {
		t.Errorf("a zone without a name: %v", err)
	}
	if _, err := Convert(everyOther{}, time.UTC, "cronwatch: x"); err == nil || !strings.Contains(err.Error(), "has a robfigcron.everyOther schedule, which CronWatch cannot read") {
		t.Errorf("a schedule of its own: %v", err)
	}
	never, err := cron.ParseStandard("0 0 30 2 *")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Convert(never, time.UTC, "cronwatch: x"); err == nil || !strings.Contains(err.Error(), "never fires") {
		t.Errorf("a date no month has: %v", err)
	}
	// Away from 02:00 the same zone converts.
	if got, err := Convert(mustParse(t, "30 4 * * *"), newYork, "x"); err != nil || got.Timezone != "America/New_York" {
		t.Errorf("04:30 in New York: %v %v", got, err)
	}
}

func mustParse(t *testing.T, spec string) cron.Schedule {
	t.Helper()
	s, err := cron.ParseStandard(spec)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

type everyOther struct{}

func (everyOther) Next(t time.Time) time.Time { return t.Add(2 * time.Hour) }

// withLocal runs fn with time.Local and $TZ set to zone, as a process
// started with TZ=zone has them.
func withLocal(t *testing.T, zone string, fn func()) {
	old := time.Local
	defer func() { time.Local = old }()
	time.Local = mustLoad(t, zone)
	t.Setenv("TZ", zone)
	fn()
}

func TestConvertTheLocalZoneByName(t *testing.T) {
	s := mustParse(t, "15 3 * * *")
	withLocal(t, "Australia/Sydney", func() {
		got, err := Convert(s, time.Local, "x")
		if err != nil {
			t.Fatal(err)
		}
		if got.Timezone != "Australia/Sydney" {
			t.Errorf("the process's zone is named: %q", got.Timezone)
		}
		// $TZ naming another zone than the one time.Local was read from is
		// not taken: the job is read in each process's own zone.
		t.Setenv("TZ", "Europe/Paris")
		got, err = Convert(mustParse(t, "15 4 * * *"), time.Local, "x")
		if err != nil {
			t.Fatal(err)
		}
		if got.Timezone != "" {
			t.Errorf("a zone that is not time.Local's: %q", got.Timezone)
		}
	})
}
