package js

import (
	"math"
	"testing"
)

func TestFormatNumber(t *testing.T) {
	a, b := 0.1, 0.2
	if got := FormatNumber(a + b); got != "0.30000000000000004" {
		t.Error(got)
	}
	cases := map[float64]string{
		0: "0", 1: "1", -1: "-1", 2.5: "2.5", 1e21: "1e+21", 1.5e21: "1.5e+21",
		1e20: "100000000000000000000", 123456789012: "123456789012", 1e-7: "1e-7", 1.23456e-10: "1.23456e-10",
		0.000001: "0.000001", 0.00005: "0.00005", -0.5: "-0.5", 1234567.891: "1234567.891", math.MaxFloat64: "1.7976931348623157e+308",
		5e-324: "5e-324", math.NaN(): "NaN", math.Inf(1): "Infinity", math.Inf(-1): "-Infinity", 100: "100", 1 / 3.0: "0.3333333333333333",
	}
	for n, want := range cases {
		if got := FormatNumber(n); got != want {
			t.Errorf("FormatNumber(%v) = %q, want %q", n, got, want)
		}
	}
}

func TestObjectOrder(t *testing.T) {
	o := &Object{}
	for _, k := range []string{"zeta", "200", "10", "b", "01", "4294967294", "4294967295", "1"} {
		o.Set(k, 1.0)
	}
	got := Stringify(o)
	want := `{"1":1,"10":1,"200":1,"4294967294":1,"zeta":1,"b":1,"01":1,"4294967295":1}`
	if got != want {
		t.Errorf("order %s, want %s", got, want)
	}
	v, err := Parse(`{"b":1,"2":2,"a":{"x":[1,"é😀\ud800",null,true]},"b":3}`)
	if err != nil {
		t.Fatal(err)
	}
	if s := Stringify(v); s != "{\"2\":2,\"b\":3,\"a\":{\"x\":[1,\"é\U0001F600�\",null,true]}}" {
		t.Errorf("parse round trip %s", s)
	}
}

func TestQuote(t *testing.T) {
	if got := Quote("a\"\\\b\f\n\r\t\x01\x1f<>& "); got != "\"a\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u001f<>& \"" {
		t.Errorf("Quote = %s", got)
	}
}

func TestUTF16(t *testing.T) {
	s := "a\U0001F600b"
	if Length16(s) != 4 {
		t.Fatal("length")
	}
	if got := Slice16(s, 0, 2); got != "a�" {
		t.Errorf("cut %q", got)
	}
	if got := Tail16(s, 2); got != "�b" {
		t.Errorf("tail %q", got)
	}
	if got := FromUnits(Units(s)); got != s {
		t.Errorf("units %q", got)
	}
}

func TestLoneSurrogates(t *testing.T) {
	s := "a\U0001F600b"
	// JavaScript: "a😀b".slice(0, 2) is "a\ud83d", .slice(2) is "\ude00b", and JSON.stringify escapes each half.
	if got := StringifyLone(Slice16Lone(s, 0, 2)); got != `"a\ud83d"` {
		t.Error(got)
	}
	if got := StringifyLone(Tail16Lone(s, 2)); got != `"\ude00b"` {
		t.Error(got)
	}
	if got := StringifyLone(Head16Lone(s, 4)); got != `"`+s+`"` {
		t.Error(got)
	}
	// Anywhere else the three bytes are not UTF-8, and Stringify writes U+FFFD for each.
	if got := Stringify(Slice16Lone(s, 0, 2)); got != `"a`+"���"+`"` {
		t.Error(got)
	}
	// Bytes that are not UTF-8 and not a lone surrogate are U+FFFD either way.
	if got := StringifyLone("x\xffy"); got != `"x`+"�"+`y"` {
		t.Error(got)
	}
}

func TestDates(t *testing.T) {
	if got := ISOString(DateUTC(2026, 0, 5, 9, 30, 0, 0)); got != "2026-01-05T09:30:00.000Z" {
		t.Error(got)
	}
	if got := ISOString(-1); got != "1969-12-31T23:59:59.999Z" {
		t.Error(got)
	}
	if got := DateUTC(2026, 2, 0, 0, 0, 0, 0); ISOString(got) != "2026-02-28T00:00:00.000Z" {
		t.Error(ISOString(got))
	}
}
