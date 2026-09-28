package js

import "fmt"

// DaysFromCivil is the days since 1970-01-01 of a proleptic Gregorian
// date, month 1 to 12.
func DaysFromCivil(y, m, d int64) int64 {
	if m <= 2 {
		y--
	}
	era := FloorDiv(y, 400)
	yoe := y - era*400
	mp := (m + 9) % 12
	doy := (153*mp+2)/5 + d - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

// CivilFromDays is the date of a day counted from 1970-01-01: year, month
// (1 to 12) and day.
func CivilFromDays(z int64) (int64, int64, int64) {
	z += 719468
	era := FloorDiv(z, 146097)
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	y := yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d := doy - (153*mp+2)/5 + 1
	m := mp + 3
	if m > 12 {
		m -= 12
	}
	if m <= 2 {
		y++
	}
	return y, m, d
}

// DateUTC is Date.UTC(year, month, day, hour, minute, second, ms) with a
// 0-based month, every field free to overflow into the next, as Date.UTC
// allows.
func DateUTC(year, month, day, hour, minute, second, ms int64) int64 {
	year += FloorDiv(month, 12)
	month = Mod(month, 12)
	days := DaysFromCivil(year, month+1, 1) + day - 1
	return days*86_400_000 + hour*3_600_000 + minute*60_000 + second*1000 + ms
}

// ISOString is new Date(ms).toISOString(): "2026-01-05T09:30:00.000Z",
// with a signed six-digit year outside 0 to 9999.
func ISOString(ms int64) string {
	days := FloorDiv(ms, 86_400_000)
	rest := ms - days*86_400_000
	y, m, d := CivilFromDays(days)
	year := fmt.Sprintf("%04d", y)
	if y < 0 {
		year = fmt.Sprintf("-%06d", -y)
	} else if y > 9999 {
		year = fmt.Sprintf("+%06d", y)
	}
	return fmt.Sprintf("%s-%02d-%02dT%02d:%02d:%02d.%03dZ", year, m, d, rest/3_600_000, rest/60_000%60, rest/1000%60, rest%1000)
}
