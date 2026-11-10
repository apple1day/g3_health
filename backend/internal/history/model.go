// Package history stores accessible HealthKit samples independently of today's snapshot.
package history

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const BatchLimit = 200

var ErrInvalid = errors.New("invalid history batch")
var ErrEpoch = errors.New("history store changed; restart synchronization")
var Kinds = []string{"sleep", "steps", "distance", "activeEnergy", "exercise", "heartRate", "workout", "activitySummary"}
var uuid = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// Values are type-specific, never totals across overlapping data sources.
type Sample struct {
	ID           string             `json:"id"`
	Kind         string             `json:"kind"`
	StartedAt    time.Time          `json:"startedAt"`
	EndedAt      time.Time          `json:"endedAt"`
	Day          string             `json:"day"`
	TimeZone     string             `json:"timeZone"`
	SourceID     string             `json:"sourceID"`
	SourceName   string             `json:"sourceName"`
	Device       string             `json:"device"`
	IsAppleWatch bool               `json:"isAppleWatch"`
	Value        *float64           `json:"value,omitempty"`
	Unit         string             `json:"unit"`
	Category     *int               `json:"category,omitempty"`
	Label        string             `json:"label"`
	Metrics      map[string]float64 `json:"metrics"`
}
type Batch struct {
	SchemaVersion int      `json:"schemaVersion"`
	Epoch         string   `json:"epoch"`
	Kind          string   `json:"kind"`
	Records       []Sample `json:"records"`
	DeletedIDs    []string `json:"deletedIDs"`
}
type Status struct {
	Epoch    string           `json:"epoch"`
	Count    int64            `json:"count"`
	Counts   map[string]int64 `json:"counts"`
	Earliest *time.Time       `json:"earliest"`
	Latest   *time.Time       `json:"latest"`
}
type Row struct {
	ID         int64     `json:"rowID"`
	Sample     Sample    `json:"sample"`
	ReceivedAt time.Time `json:"receivedAt"`
}
type Page struct {
	Items      []Row  `json:"items"`
	Total      int64  `json:"total"`
	NextCursor string `json:"nextCursor"`
}
type Filter struct {
	Kind, From, To     string
	BeforeNS, BeforeID int64
	Limit              int
}

func ValidKind(k string) bool {
	for _, v := range Kinds {
		if k == v {
			return true
		}
	}
	return false
}
func ValidDay(s string) bool {
	t, e := time.Parse("2006-01-02", s)
	return e == nil && t.Format("2006-01-02") == s
}
func ValidID(kind, id string) bool {
	if kind == "activitySummary" {
		return ValidDay(id)
	}
	return uuid.MatchString(id)
}
func GoodTime(t time.Time) bool { return !t.IsZero() && t.Year() >= 1970 && t.Year() <= 2200 }
func Parse(raw []byte, now time.Time) (Batch, error) {
	var b Batch
	if !utf8.Valid(raw) || UniqueJSON(raw) != nil {
		return b, ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&b) != nil || b.SchemaVersion != 1 || !uuid.MatchString(b.Epoch) || !ValidKind(b.Kind) || b.Records == nil || b.DeletedIDs == nil || len(b.Records)+len(b.DeletedIDs) > BatchLimit {
		return b, ErrInvalid
	}
	seen := map[string]bool{}
	for i := range b.Records {
		r := &b.Records[i]
		if r.Kind != b.Kind || !ValidID(r.Kind, r.ID) || seen[r.ID] || !GoodTime(r.StartedAt) || !GoodTime(r.EndedAt) || r.EndedAt.Before(r.StartedAt) || r.StartedAt.After(now.Add(5*time.Minute)) || r.EndedAt.After(now.Add(5*time.Minute)) {
			return b, ErrInvalid
		}
		seen[r.ID] = true
		loc, e := time.LoadLocation(r.TimeZone)
		if e != nil || r.TimeZone == "" || len(r.TimeZone) > 80 || !ValidDay(r.Day) || r.StartedAt.In(loc).Format("2006-01-02") != r.Day {
			return b, ErrInvalid
		}
		for _, s := range []string{r.SourceID, r.SourceName, r.Device, r.Label} {
			if len([]rune(s)) > 160 || strings.ContainsAny(s, "\x00\r\n") {
				return b, ErrInvalid
			}
		}
		if r.SourceID == "" || r.SourceName == "" || r.Metrics == nil || len(r.Metrics) > 10 {
			return b, ErrInvalid
		}
		if r.Value != nil && (!finite(*r.Value) || r.Kind == "heartRate" && *r.Value <= 0) {
			return b, ErrInvalid
		}
		unit := map[string]string{"sleep": "min", "steps": "count", "distance": "m", "activeEnergy": "kcal", "exercise": "min", "heartRate": "bpm", "workout": "s", "activitySummary": "day"}[r.Kind]
		if r.Unit != unit {
			return b, ErrInvalid
		}
		allowedMetrics := map[string]bool{}
		switch r.Kind {
		case "sleep":
			if r.Category == nil || *r.Category < 0 || *r.Category > 100 || r.Value == nil {
				return b, ErrInvalid
			}
		case "workout":
			if r.Value == nil || r.Category != nil {
				return b, ErrInvalid
			}
			allowedMetrics = map[string]bool{"distanceMeters": true, "activeEnergyKcal": true}
		case "activitySummary":
			if r.ID != r.Day || r.Value != nil || r.Category != nil {
				return b, ErrInvalid
			}
			for _, k := range []string{"activeEnergyKcal", "exerciseMinutes", "standHours", "activeEnergyGoalKcal", "exerciseGoalMinutes", "standGoalHours", "moveMinutes", "moveGoalMinutes"} {
				allowedMetrics[k] = true
			}
		default:
			if r.Value == nil || r.Category != nil {
				return b, ErrInvalid
			}
		}
		for k, v := range r.Metrics {
			if !allowedMetrics[k] || !finite(v) {
				return b, ErrInvalid
			}
		}
		r.StartedAt = r.StartedAt.UTC()
		r.EndedAt = r.EndedAt.UTC()
	}
	for _, id := range b.DeletedIDs {
		if !ValidID(b.Kind, id) || seen[id] {
			return b, ErrInvalid
		}
		seen[id] = true
	}
	return b, nil
}
func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= 0 }

// Reject ambiguous duplicate keys, deeply nested payloads and trailing JSON.
func UniqueJSON(raw []byte) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 12 {
			return ErrInvalid
		}
		t, e := d.Token()
		if e != nil {
			return e
		}
		if delim, ok := t.(json.Delim); ok {
			if delim == '{' {
				seen := map[string]bool{}
				for d.More() {
					k, e := d.Token()
					if e != nil {
						return e
					}
					s, ok := k.(string)
					if !ok || seen[s] {
						return ErrInvalid
					}
					seen[s] = true
					if e = walk(depth + 1); e != nil {
						return e
					}
				}
				_, e = d.Token()
				return e
			}
			if delim == '[' {
				for d.More() {
					if e = walk(depth + 1); e != nil {
						return e
					}
				}
				_, e = d.Token()
				return e
			}
			return ErrInvalid
		}
		return nil
	}
	if e := walk(0); e != nil {
		return e
	}
	if _, e := d.Token(); e != io.EOF {
		return ErrInvalid
	}
	return nil
}
func Cursor(ns, id int64) string {
	return base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(ns, 10) + ":" + strconv.FormatInt(id, 10)))
}
func DecodeCursor(s string) (int64, int64, error) {
	if s == "" {
		return 0, 0, nil
	}
	if len(s) > 100 {
		return 0, 0, ErrInvalid
	}
	b, e := base64.RawURLEncoding.DecodeString(s)
	if e != nil {
		return 0, 0, ErrInvalid
	}
	p := strings.Split(string(b), ":")
	if len(p) != 2 {
		return 0, 0, ErrInvalid
	}
	ns, e1 := strconv.ParseInt(p[0], 10, 64)
	id, e2 := strconv.ParseInt(p[1], 10, 64)
	if e1 != nil || e2 != nil || ns < 0 || id < 1 {
		return 0, 0, ErrInvalid
	}
	return ns, id, nil
}
