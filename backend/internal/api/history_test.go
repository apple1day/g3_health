package api

import (
	"context"
	"encoding/json"
	"github.com/apple1day/g3_health/backend/internal/config"
	"github.com/apple1day/g3_health/backend/internal/history"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

type historyFake struct {
	fake
	batches int
	filter  history.Filter
}

func (f *historyFake) HistoryStatus(context.Context) (history.Status, error) {
	return history.Status{Epoch: "00112233-4455-4677-8899-aabbccddeeff", Counts: map[string]int64{}}, nil
}
func (f *historyFake) HistoryList(_ context.Context, filter history.Filter) (history.Page, error) {
	f.filter = filter
	return history.Page{Items: []history.Row{}, Sources: []history.SourceSummary{}}, nil
}

func TestHistorySourceFilters(t *testing.T) {
	f := &historyFake{}
	r := New(config.Default(), f)
	for _, prefix := range []string{"/v1/history/records", "/api/admin/records"} {
		source := "com.heytap.health"
		q := url.Values{"kind": {"sleep"}, "from": {"2018-01-01"}, "to": {"2018-01-02"}, "sourceID": {source}, "limit": {"1"}, "cursor": {history.Cursor(10, 20)}}
		w := call(r, "GET", prefix+"?"+q.Encode(), "", nil)
		if w.Code != 200 || f.filter.SourceID != source || f.filter.Kind != "sleep" || f.filter.From != "2018-01-01" || f.filter.To != "2018-01-02" || f.filter.BeforeID != 20 || f.filter.Limit != 1 {
			t.Fatal("source/date/page filter lost", prefix, w.Code, f.filter)
		}
		var page history.Page
		if json.Unmarshal(w.Body.Bytes(), &page) != nil || page.Sources == nil {
			t.Fatal("source inventory must be an array")
		}
		for _, invalid := range []string{strings.Repeat("a", 161), "a\nb", "a\rb", "a\x00b", string([]byte{0xff})} {
			q.Set("sourceID", invalid)
			if w := call(r, "GET", prefix+"?"+q.Encode(), "", nil); w.Code != 400 {
				t.Fatal("invalid source accepted", prefix, w.Code)
			}
		}
		for _, exact := range []string{strings.Repeat("欢", 160), "foo' OR 1=1 --", "com.heytap.health "} {
			q.Set("sourceID", exact)
			if w := call(r, "GET", prefix+"?"+q.Encode(), "", nil); w.Code != 200 || f.filter.SourceID != exact {
				t.Fatal("opaque source was changed", prefix, w.Code)
			}
		}
	}
}
func (f *historyFake) ApplyHistory(_ context.Context, b history.Batch) error {
	if b.Epoch != "00112233-4455-4677-8899-aabbccddeeff" {
		return history.ErrEpoch
	}
	f.batches++
	return nil
}
func TestHistoryAPIValidationAndOrigin(t *testing.T) {
	f := &historyFake{}
	r := New(config.Default(), f)
	for _, path := range []string{"/v1/history/status", "/v1/history/records", "/api/admin/records/status", "/api/admin/records"} {
		if w := call(r, "GET", path, "", nil); w.Code != 200 {
			t.Fatal(path, w.Code)
		}
	}
	b := history.Batch{SchemaVersion: 1, Epoch: "00112233-4455-4677-8899-aabbccddeeff", Kind: "sleep", Records: []history.Sample{}, DeletedIDs: []string{}}
	raw, _ := json.Marshal(b)
	if w := call(r, "PUT", "/v1/history/batch", "", raw); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	for _, path := range []string{"/v1/history/records?limit=101", "/v1/history/records?kind=other", "/api/admin/records?cursor=bad", "/v1/history/records?from=2020-03-02&to=2020-01-01"} {
		if w := call(r, "GET", path, "", nil); w.Code != 400 {
			t.Fatal(path, w.Code)
		}
	}
	b.Epoch = "00112233-4455-4677-8899-aabbccddee00"
	raw, _ = json.Marshal(b)
	if w := call(r, "PUT", "/v1/history/batch", "", raw); w.Code != 409 {
		t.Fatal("epoch", w.Code)
	}
	if w := call(r, "PUT", "/v1/history/batch", "", []byte(`{"secret":"never-echo"}`)); w.Code != 422 || strings.Contains(w.Body.String(), "never-echo") {
		t.Fatal("leaked payload")
	}
	if w := call(r, "PUT", "/v1/history/batch", "", []byte(strings.Repeat("x", 1024*1024+1))); w.Code != 413 {
		t.Fatal("limit", w.Code)
	}
	q := httptest.NewRequest("GET", "/api/admin/records", nil)
	q.Header.Set("Origin", "https://external.example")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, q)
	if w.Code != 403 {
		t.Fatal("origin not checked")
	}
}
