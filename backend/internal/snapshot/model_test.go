package snapshot

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

const fixture = `{"schemaVersion":1,"dataMode":"healthkit","generatedAt":"2026-11-10T02:00:00Z","timeZone":"Asia/Shanghai","day":"2026-11-10","sourcePolicy":"healthKit","sleep":{"status":"empty"},"activity":{"status":"ok","steps":0,"moveMode":"energy"},"heartRate":{"status":"empty"},"workout":{"status":"empty"},"warnings":[]}`

func TestValidOptionalNulls(t *testing.T) {
	s, e := Parse([]byte(fixture), time.Date(2026, 11, 10, 2, 1, 0, 0, time.UTC))
	if e != nil {
		t.Fatal(e)
	}
	if s.Sleep.TotalMinutes != nil || s.Activity.Steps == nil || *s.Activity.Steps != 0 {
		t.Fatal("null / zero distinction lost")
	}
}
func TestValidation(t *testing.T) {
	cases := map[string]string{
		"demo":             strings.Replace(fixture, `"healthkit"`, `"demo"`, 1),
		"duplicate":        strings.Replace(fixture, `"steps":0`, `"steps":0,"steps":1`, 1),
		"escapedDuplicate": strings.Replace(fixture, `"steps":0`, `"steps":0,"st\u0065ps":1`, 1),
		"unknown":          strings.Replace(fixture, `"steps":0`, `"steps":0,"token":"secret"`, 1),
		"negative":         strings.Replace(fixture, `"steps":0`, `"steps":-1`, 1),
		"nan":              strings.Replace(fixture, `"steps":0`, `"steps":NaN`, 1),
		"stringNumber":     strings.Replace(fixture, `"steps":0`, `"steps":"10"`, 1),
		"nullSection":      strings.Replace(fixture, `"sleep":{"status":"empty"}`, `"sleep":null`, 1),
		"badZone":          strings.Replace(fixture, `Asia/Shanghai`, `Invalid/Zone`, 1),
		"wrongDay":         strings.Replace(fixture, `"day":"2026-11-10"`, `"day":"2026-11-09"`, 1),
		"booleanVersion":   strings.Replace(fixture, `"schemaVersion":1`, `"schemaVersion":true`, 1),
		"floatVersion":     strings.Replace(fixture, `"schemaVersion":1`, `"schemaVersion":1.0`, 1),
		"heartNoTime":      strings.Replace(fixture, `"heartRate":{"status":"empty"}`, `"heartRate":{"status":"ok","bpm":70}`, 1),
		"naiveTime":        strings.Replace(fixture, `02:00:00Z`, `02:00:00`, 1),
		"nullWarnings":     strings.Replace(fixture, `"warnings":[]`, `"warnings":null`, 1),
		"trailing":         fixture + `{}`,
		"badInterval":      strings.Replace(fixture, `"sleep":{"status":"empty"}`, `"sleep":{"status":"ok","startedAt":"2026-11-10T02:00:00Z","endedAt":"2026-11-09T02:00:00Z"}`, 1),
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if _, e := Parse([]byte(raw), time.Date(2026, 11, 10, 2, 1, 0, 0, time.UTC)); e == nil {
				t.Fatal("accepted invalid data")
			}
		})
	}
}
func TestFutureRejected(t *testing.T) {
	if _, e := Parse([]byte(fixture), time.Date(2026, 11, 9, 2, 1, 0, 0, time.UTC)); e == nil {
		t.Fatal("future accepted")
	}
}
func TestCredentialRejected(t *testing.T) {
	raw := strings.Replace(fixture, `"warnings":[]`, `"warnings":["test-upload-credential-00000000000000000"]`, 1)
	if _, e := Parse([]byte(raw), time.Date(2026, 11, 10, 2, 1, 0, 0, time.UTC), "test-upload-credential-00000000000000000"); e == nil {
		t.Fatal("credential accepted")
	}
}
func TestCanonicalTimeOffsets(t *testing.T) {
	now := time.Date(2026, 11, 10, 2, 1, 0, 0, time.UTC)
	a, _ := Parse([]byte(fixture), now)
	b, e := Parse([]byte(strings.Replace(fixture, "02:00:00Z", "10:00:00+08:00", 1)), now)
	if e != nil {
		t.Fatal(e)
	}
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	if string(x) != string(y) {
		t.Fatal("canonical representations differ")
	}
}
