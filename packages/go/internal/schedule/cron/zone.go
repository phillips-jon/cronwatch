package cron

import (
	"archive/zip"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"cronwatch.dev/go/internal/js"
)

// Zones are Go's own zone database (the system's, $ZONEINFO, or the one
// an app embeds by importing time/tzdata), named as Intl names them:
// without regard to case, so "america/new_york" is New York, as
// Intl.DateTimeFormat reads it. A fixed offset ("+05:30", "-0800", "+05")
// is a zone too, since Intl and croner both take one.

var (
	zoneMu    sync.Mutex
	zoneCache = map[string]*time.Location{}
	zoneNames map[string]string // lowercased name to the database's spelling, built on first need
)

// LoadZone is the zone an IANA name (or a fixed offset) names, matched
// without regard to case; "" is the process's own zone, time.Local.
func LoadZone(name string) (*time.Location, error) {
	if name == "" {
		return time.Local, nil
	}
	zoneMu.Lock()
	defer zoneMu.Unlock()
	if loc, ok := zoneCache[name]; ok {
		return loc, nil
	}
	loc, err := loadZone(name)
	if err != nil {
		return nil, err
	}
	if len(zoneCache) >= 1000 {
		zoneCache = map[string]*time.Location{}
	}
	zoneCache[name] = loc
	return loc, nil
}

func loadZone(name string) (*time.Location, error) {
	bad := fmt.Errorf("unknown time zone %q", name)
	// "Local" is Go's name for the process zone, not an IANA zone.
	if strings.EqualFold(name, "local") || strings.ContainsRune(name, 0) {
		return nil, bad
	}
	if loc, ok := fixedOffset(name); ok {
		return loc, nil
	}
	if strings.EqualFold(name, "utc") {
		return time.UTC, nil
	}
	if loc, err := time.LoadLocation(name); err == nil {
		return loc, nil
	}
	if zoneNames == nil {
		zoneNames = indexZones()
	}
	if canonical, ok := zoneNames[strings.ToLower(name)]; ok {
		if loc, err := time.LoadLocation(canonical); err == nil {
			return loc, nil
		}
	}
	return nil, bad
}

// fixedOffset reads "+HH", "+HHMM", or "+HH:MM" (or "-"), as Intl reads an
// offset time zone.
func fixedOffset(name string) (*time.Location, bool) {
	if len(name) < 3 || (name[0] != '+' && name[0] != '-') {
		return nil, false
	}
	rest := name[1:]
	var hh, mm string
	switch len(rest) {
	case 2:
		hh, mm = rest, "00"
	case 4:
		hh, mm = rest[:2], rest[2:]
	case 5:
		if rest[2] != ':' {
			return nil, false
		}
		hh, mm = rest[:2], rest[3:]
	default:
		return nil, false
	}
	h, err1 := strconv.Atoi(hh)
	m, err2 := strconv.Atoi(mm)
	if err1 != nil || err2 != nil || h > 23 || m > 59 || strings.ContainsAny(hh+mm, "+-") {
		return nil, false
	}
	sec := (h*60 + m) * 60
	if name[0] == '-' {
		sec = -sec
	}
	return time.FixedZone(name, sec), true
}

// indexZones lists every zone name the database has, lowercased, from the
// places Go's time package reads zones from.
func indexZones() map[string]string {
	names := map[string]string{}
	add := func(name string) {
		if name == "" || strings.ContainsAny(name, ".") || strings.HasPrefix(name, "posix/") || strings.HasPrefix(name, "right/") {
			return
		}
		if _, ok := names[strings.ToLower(name)]; !ok {
			names[strings.ToLower(name)] = name
		}
	}
	walkDir := func(root string) {
		_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			if rel, err := filepath.Rel(root, path); err == nil {
				add(filepath.ToSlash(rel))
			}
			return nil
		})
	}
	walkZip := func(file string) {
		r, err := zip.OpenReader(file)
		if err != nil {
			return
		}
		defer r.Close()
		for _, f := range r.File {
			if !strings.HasSuffix(f.Name, "/") {
				add(f.Name)
			}
		}
	}
	if env := os.Getenv("ZONEINFO"); env != "" {
		if info, err := os.Stat(env); err == nil && info.IsDir() {
			walkDir(env)
		} else {
			walkZip(env)
		}
	}
	for _, dir := range []string{"/usr/share/zoneinfo", "/usr/share/lib/zoneinfo", "/usr/lib/locale/TZ", "/etc/zoneinfo"} {
		walkDir(dir)
	}
	// The same file time.LoadLocation falls back to.
	//lint:ignore SA1019 time.LoadLocation itself reads runtime.GOROOT's zoneinfo.zip
	walkZip(filepath.Join(runtime.GOROOT(), "lib", "time", "zoneinfo.zip"))
	return names
}

// Offset is the seconds a zone's wall clock is ahead of UTC at epoch
// second sec.
func Offset(sec int64, loc *time.Location) int64 {
	_, off := time.Unix(sec, 0).In(loc).Zone()
	return int64(off)
}

// wall is the wall clock at epoch second sec: year, month (1 to 12), day,
// hour, minute, second.
type wall [6]int64

func wallAt(sec int64, loc *time.Location) wall {
	local := sec + Offset(sec, loc)
	days := js.FloorDiv(local, 86_400)
	rest := local - days*86_400
	y, m, d := js.CivilFromDays(days)
	return wall{y, m, d, rest / 3600, rest % 3600 / 60, rest % 60}
}

// civilSeconds is a wall-clock time read as if it were UTC, in epoch
// seconds (croner's T()).
func civilSeconds(w wall) int64 {
	return js.FloorDiv(js.DateUTC(w[0], w[1]-1, w[2], w[3], w[4], w[5], 0), 1000)
}

// toUTC is croner's fromTZ: the instant a wall-clock time names, in epoch
// seconds. A time in a spring-forward gap moves forward by the gap; a
// time that happens twice (fall back) is the earlier of the two.
func toUTC(w wall, loc *time.Location) int64 {
	target := civilSeconds(w)
	guess := target + (target - civilSeconds(wallAt(target, loc)))
	seen := wallAt(guess, loc)
	if seen == w {
		earlier := guess - 3600
		if wallAt(earlier, loc) == w {
			return earlier
		}
		return guess
	}
	shifted := guess + target - civilSeconds(seen)
	if wallAt(shifted, loc) == w {
		return shifted
	}
	return max(guess, shifted)
}
