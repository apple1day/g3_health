package history

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func testBatch() Batch {
	start := time.Date(2018, 1, 1, 22, 0, 0, 0, time.UTC)
	v := 60.0
	cat := 3
	return Batch{SchemaVersion: 1, Epoch: "00112233-4455-4677-8899-aabbccddeeff", Kind: "sleep", Records: []Sample{{ID: "11223344-5566-4788-9900-aabbccddeeff", Kind: "sleep", StartedAt: start, EndedAt: start.Add(time.Hour), Day: "2018-01-01", TimeZone: "UTC", SourceID: "watch", SourceName: "Apple Watch", Device: "Watch", IsAppleWatch: true, Value: &v, Unit: "min", Category: &cat, Label: "核心睡眠", Metrics: map[string]float64{}}}, DeletedIDs: []string{}}
}
func TestHistoricalRecordsAndStrictValidation(t *testing.T) {
	b := testBatch()
	raw, _ := json.Marshal(b)
	if _, e := Parse(raw, time.Now()); e != nil {
		t.Fatal(e)
	}
	tests := []string{
		strings.Replace(string(raw), `"schemaVersion":1`, `"schemaVersion":2`, 1),
		strings.Replace(string(raw), `"schemaVersion":1`, `"schemaVersion":true`, 1),
		strings.Replace(string(raw), `"schemaVersion":1`, `"schemaVersion":1.0`, 1),
		strings.Replace(string(raw), `"schemaVersion":1`, `"schemaVersion":1,"schemaVersion":1`, 1),
		strings.Replace(string(raw), `"value":60`, `"value":-1`, 1),
		strings.Replace(string(raw), `"value":60`, `"value":"60"`, 1),
		strings.Replace(string(raw), `"day":"2018-01-01"`, `"day":"2020-02-30"`, 1),
		strings.Replace(string(raw), `"timeZone":"UTC"`, `"timeZone":"not-a-zone"`, 1),
		strings.Replace(string(raw), `"unit":"min"`, `"unit":"h"`, 1),
		strings.Replace(string(raw), `"metrics":{}`, `"metrics":{"unknown":1}`, 1),
		strings.Replace(string(raw), `"records":[`, `"secret":"not-stored","records":[`, 1),
		string(raw) + `{}`,
	}
	for _, raw := range tests {
		if _, e := Parse([]byte(raw), time.Now()); e == nil {
			t.Error("invalid batch accepted")
		}
	}
}
func TestSourceIdentityLimits(t *testing.T) {
	for _, source := range []string{"com.heytap.health", "com.heytap.health ", "foo' OR 1=1 --", strings.Repeat("欢", 160)} {
		b := testBatch()
		b.Records[0].SourceID, b.Records[0].SourceName = source, strings.Repeat("太", 160)
		raw, _ := json.Marshal(b)
		parsed, err := Parse(raw, time.Now())
		if err != nil || parsed.Records[0].SourceID != source {
			t.Fatal("valid source identity changed", err)
		}
	}
	for _, source := range []string{"", strings.Repeat("a", 161), strings.Repeat("欢", 161), "source\nname", "source\rname", "source\x00name"} {
		for _, field := range []string{"id", "name"} {
			b := testBatch()
			if field == "id" {
				b.Records[0].SourceID = source
			} else {
				b.Records[0].SourceName = source
			}
			raw, _ := json.Marshal(b)
			if _, err := Parse(raw, time.Now()); err == nil {
				t.Fatal("invalid source accepted", field)
			}
		}
	}
}
func TestLimitsOverlapAndDeletion(t *testing.T) {
	b := testBatch()
	b.DeletedIDs = append(b.DeletedIDs, b.Records[0].ID)
	raw, _ := json.Marshal(b)
	if _, e := Parse(raw, time.Now()); e == nil {
		t.Fatal("overlap accepted")
	}
	b.Records = []Sample{}
	raw, _ = json.Marshal(b)
	if _, e := Parse(raw, time.Now()); e != nil {
		t.Fatal("delete only failed", e)
	}
	b.Records = nil
	raw, _ = json.Marshal(b)
	if _, e := Parse(raw, time.Now()); e == nil {
		t.Fatal("null array accepted")
	}
	b = testBatch()
	for len(b.Records) < 201 {
		b.Records = append(b.Records, b.Records[0])
	}
	raw, _ = json.Marshal(b)
	if _, e := Parse(raw, time.Now()); e == nil {
		t.Fatal("oversized batch accepted")
	}
}
func TestCursorSameTimestampAndInvalid(t *testing.T) {
	ns := int64(1546300800000000000)
	id := int64(123)
	a, b, e := DecodeCursor(Cursor(ns, id))
	if e != nil || a != ns || b != id {
		t.Fatal("cursor roundtrip")
	}
	for _, s := range []string{"%%%", "eDox", "LTE6MQ", "MTotMQ", strings.Repeat("x", 101)} {
		if _, _, e := DecodeCursor(s); e == nil {
			t.Fatal("invalid cursor accepted")
		}
	}
}
