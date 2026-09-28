// Package bridge is what the scheduler integrations share: the robfigcron,
// gocron, river and asynq modules beside this one, each a module of its
// own. It uses the standard library only, so it lives in the core module.
// An app does not need it; a scheduler integration of your own can.
//
//   - Watch declares a scheduler's entries as jobs, one per name, tagged
//     with the integration and the app, and declares a job whose entry is
//     gone again without its schedule, so it is never reported missed.
//   - CheckFires checks a schedule converted from a scheduler's own against
//     the scheduler's own fire times.
//   - FieldText, EveryText and Zone write what a scheduler holds as the
//     schedule text CronWatch reads.
//
// Which jobs are this app's is told by two tags, the integration's
// ("robfig-cron") and the app's under it ("robfig-cron:<app>", see
// AppTag), so two apps sharing one store never declare each other's jobs
// without a schedule. That is the PHP port's rule for Laravel and Symfony
// (Cronwatch\Bridge\Unscheduled).
package bridge

import (
	"crypto/md5"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"cronwatch.dev/go/internal/schedule"
)

// AppName is the app's name for its tag: $CRONWATCH_APP_ID when set, else
// the name of the running executable. Two apps that share a store and run
// executables of the same name need CRONWATCH_APP_ID (or the integration's
// App option) to tell them apart; every process of one app needs the same.
func AppName() string {
	if id := strings.TrimSpace(os.Getenv("CRONWATCH_APP_ID")); id != "" {
		return id
	}
	if exe, err := os.Executable(); err == nil {
		if name := strings.TrimSuffix(filepath.Base(exe), ".exe"); name != "" && name != "." {
			return name
		}
	}
	return strings.TrimSuffix(filepath.Base(os.Args[0]), ".exe")
}

var (
	notSlug   = regexp.MustCompile(`[^a-z0-9._-]+`)
	validName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$`)
	// A function literal's generated name: "main.main.func1", "jobs.init.0.func2".
	generated = regexp.MustCompile(`(^|\.)(func\d+|glob|init)(\.|$)|\[`)
)

// ValidName reports whether name is a CronWatch job name: 1 to 120
// letters, digits, ".", "_", ":" or "-", starting with a letter or digit.
func ValidName(name string) bool { return validName.MatchString(name) }

// FuncName is a job name from a function's name as the runtime writes it
// (runtime.FuncForPC): without its package's path ("jobs.NightlyReport"),
// a method value without its receiver's star and "-fm"
// ("jobs.Reporter.Run"). A function literal ("main.main.func1") has no
// stable name, since it changes when the code around it does, and is
// refused, as is a name CronWatch does not take.
func FuncName(full string) (string, error) {
	name := full[strings.LastIndex(full, "/")+1:]
	name = strings.TrimSuffix(name, "-fm")
	name = strings.NewReplacer("(*", "", ")", "").Replace(name)
	if generated.MatchString(name) {
		return "", errors.New("is a function literal (" + full + "), whose name changes when the code around it does")
	}
	if !validName.MatchString(name) {
		return "", errors.New("is named " + name + ", which is not a CronWatch job name")
	}
	return name, nil
}

// AppTag is the tag that names the app under an integration's tag:
// "<tag>:<app>", the app's name lowercased, with anything but letters,
// digits, ".", "_" and "-" made "-". A name that is empty once cleaned, or
// longer than 48 characters, is cut and given 8 hex characters of its MD5,
// so two names never share a tag. The PHP port's appTag(), character for
// character.
func AppTag(tag, app string) string {
	// ASCII letters only, as PHP 8's strtolower (so the Kelvin sign is not a "k").
	lower := strings.Map(func(r rune) rune {
		if r >= 'A' && r <= 'Z' {
			return r + 32
		}
		return r
	}, strings.Trim(app, " \t\n\r\x00\x0B"))
	slug := strings.Trim(notSlug.ReplaceAllString(lower, "-"), "-")
	if slug == "" || len(slug) > 48 {
		sum := md5.Sum([]byte(app))
		slug = strings.TrimLeft(slug[:min(len(slug), 39)]+"-", "-") + hex.EncodeToString(sum[:])[:8]
	}
	return tag + ":" + slug
}

// FieldText is a cron field for a set of values from lo to hi: "*" for all
// of them, "*/n" for a step from lo (three values or more), else a list
// with runs of three or more as ranges. "" for none.
func FieldText(values []int, lo, hi int) string {
	found := slices.Clone(values)
	slices.Sort(found)
	found = slices.Compact(found)
	every := func(step int) []int {
		var out []int
		for v := lo; v <= hi; v += step {
			out = append(out, v)
		}
		return out
	}
	if slices.Equal(found, every(1)) {
		return "*"
	}
	for step := 2; step <= hi-lo; step++ {
		if len(found) > 2 && slices.Equal(found, every(step)) {
			return "*/" + strconv.Itoa(step)
		}
	}
	var parts []string
	for i := 0; i < len(found); {
		j := i
		for j+1 < len(found) && found[j+1] == found[j]+1 {
			j++
		}
		if j-i >= 2 {
			parts = append(parts, strconv.Itoa(found[i])+"-"+strconv.Itoa(found[j]))
		} else {
			for _, v := range found[i : j+1] {
				parts = append(parts, strconv.Itoa(v))
			}
		}
		i = j + 1
	}
	return strings.Join(parts, ",")
}

// EveryText is an interval as CronWatch's schedule text, exact to the
// millisecond: "every 1h30m".
func EveryText(d time.Duration) string {
	ms := (d + time.Millisecond/2) / time.Millisecond
	var b strings.Builder
	for _, unit := range []struct {
		name string
		size time.Duration
	}{{"d", 86_400_000}, {"h", 3_600_000}, {"m", 60_000}, {"s", 1000}, {"ms", 1}} {
		if ms >= unit.size {
			b.WriteString(strconv.FormatInt(int64(ms/unit.size), 10) + unit.name)
			ms %= unit.size
		}
	}
	if b.Len() == 0 {
		return "every 0ms"
	}
	return "every " + b.String()
}

// Zone is the IANA name CronWatch reads a scheduler's zone as. The
// process's own zone (time.Local) is named by $TZ or where /etc/localtime
// points, so a check in another process reads the schedule in the same
// zone; "" when it cannot be named, which CronWatch reads as each
// process's own zone. False for a zone that is not an IANA zone.
func Zone(loc *time.Location) (string, bool) {
	if loc == nil || loc == time.Local {
		return localZone(), true
	}
	name := loc.String()
	if schedule.IsTimezone(name) {
		return name, true
	}
	return "", false
}

// localZone is the process's zone by its IANA name, or "": $TZ, else
// where /etc/localtime points, taken only when its offsets are time.Local's
// through the next few years (time.Local is read once, so $TZ may have
// changed since).
func localZone() string {
	candidate := ""
	if tz, set := os.LookupEnv("TZ"); set {
		candidate = strings.TrimPrefix(tz, ":")
		if candidate == "" {
			candidate = "UTC"
		}
	} else if target, err := filepath.EvalSymlinks("/etc/localtime"); err == nil {
		_, candidate, _ = strings.Cut(target, "zoneinfo/")
	}
	if candidate == "" || !schedule.IsTimezone(candidate) {
		return ""
	}
	loc, err := schedule.LoadZone(candidate)
	if err != nil {
		return ""
	}
	start := time.Now().UTC()
	for week := 0; week < 5*53; week++ {
		at := start.AddDate(0, 0, 7*week)
		_, want := at.In(time.Local).Zone()
		_, got := at.In(loc).Zone()
		if want != got {
			return ""
		}
	}
	return candidate
}
