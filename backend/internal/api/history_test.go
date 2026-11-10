package api

import (
	"context"
	"encoding/json"
	"github.com/apple1day/g3_health/backend/internal/config"
	"github.com/apple1day/g3_health/backend/internal/history"
	"net/http/httptest"
	"strings"
	"testing"
)

type historyFake struct {
	fake
	batches int
}

func (f *historyFake) HistoryStatus(context.Context) (history.Status, error) {
	return history.Status{Epoch: "00112233-4455-4677-8899-aabbccddeeff", Counts: map[string]int64{}}, nil
}
func (f *historyFake) HistoryList(context.Context, history.Filter) (history.Page, error) {
	return history.Page{Items: []history.Row{}}, nil
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
