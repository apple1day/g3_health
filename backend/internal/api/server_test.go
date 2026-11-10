package api

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/apple1day/g3_health/backend/internal/config"
	"github.com/apple1day/g3_health/backend/internal/snapshot"
	"github.com/apple1day/g3_health/backend/internal/store"
	"github.com/apple1day/g3_health/backend/internal/testutil"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fake struct{ records []store.Record }

func (f *fake) Ping(context.Context) error { return nil }
func (f *fake) Put(_ context.Context, s snapshot.Snapshot) (time.Time, error) {
	if len(f.records) > 0 {
		last := f.records[len(f.records)-1]
		if s.GeneratedAt.Before(last.Snapshot.GeneratedAt) {
			return time.Time{}, store.ErrConflict
		}
		if s.GeneratedAt.Equal(last.Snapshot.GeneratedAt) {
			a, _ := json.Marshal(s)
			b, _ := json.Marshal(last.Snapshot)
			if !bytes.Equal(a, b) {
				return time.Time{}, store.ErrConflict
			}
			return last.ReceivedAt, nil
		}
	}
	r := store.Record{ID: int64(len(f.records) + 1), Snapshot: s, ReceivedAt: time.Now().UTC()}
	f.records = append(f.records, r)
	return r.ReceivedAt, nil
}
func (f *fake) Latest(context.Context) (store.Record, error) {
	if len(f.records) == 0 {
		return store.Record{}, store.ErrNotFound
	}
	return f.records[len(f.records)-1], nil
}
func (f *fake) DeleteAll(context.Context) error { f.records = nil; return nil }
func (f *fake) Overview(context.Context) (store.Overview, error) {
	o := store.Overview{Count: int64(len(f.records))}
	if len(f.records) > 0 {
		v := f.records[len(f.records)-1]
		o.Latest = &v
	}
	return o, nil
}
func (f *fake) List(_ context.Context, q store.Filter) (store.Page, error) {
	return store.Page{Items: f.records, Total: int64(len(f.records)), Page: q.Page, PageSize: q.PageSize}, nil
}
func (f *fake) Days(context.Context, store.Filter) ([]store.Record, error) { return f.records, nil }
func (f *fake) Get(_ context.Context, id int64) (store.Record, error) {
	for _, r := range f.records {
		if r.ID == id {
			return r, nil
		}
	}
	return store.Record{}, store.ErrNotFound
}

// legacyAuth is used only to verify backwards-compatible header ignoring.
func call(r http.Handler, method, path, legacyAuth string, body []byte) *httptest.ResponseRecorder {
	q := httptest.NewRequest(method, path, bytes.NewReader(body))
	q.Header.Set("Content-Type", "application/json")
	if legacyAuth != "" {
		q.Header.Set("Authorization", "Bearer "+legacyAuth)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, q)
	return w
}
func TestNoTokenLifecycle(t *testing.T) {
	r := New(config.Default(), &fake{})
	raw := testutil.Raw(time.Now().Add(-time.Minute))
	cases := []struct {
		method, path string
		body         []byte
		want         int
	}{
		{"GET", "/healthz", nil, 200}, {"GET", "/v1/snapshot", nil, 404},
		{"GET", "/api/admin/me", nil, 200}, {"GET", "/api/admin/overview", nil, 200},
		{"PUT", "/v1/snapshot", raw, 200}, {"PUT", "/v1/snapshot", raw, 200},
		{"GET", "/v1/snapshot", nil, 200}, {"GET", "/api/admin/snapshots/1", nil, 200},
		{"GET", "/api/admin/snapshots?page=0", nil, 400},
		{"GET", "/api/admin/days?from=2025-01-01&to=2026-12-01", nil, 400},
		{"GET", "/api/admin/days", nil, 400},
		{"DELETE", "/v1/snapshot", nil, 204}, {"DELETE", "/v1/snapshot", nil, 204},
		{"GET", "/v1/snapshot", nil, 404},
	}
	for _, tc := range cases {
		w := call(r, tc.method, tc.path, "", tc.body)
		if w.Code != tc.want {
			t.Fatalf("%s %s: got %d want %d: %s", tc.method, tc.path, w.Code, tc.want, w.Body.String())
		}
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("private response policy lost")
		}
		if w.Header().Get("WWW-Authenticate") != "" {
			t.Fatal("unexpected authentication challenge")
		}
	}
}
func TestLegacyCredentialsDoNotGateAnyEndpoint(t *testing.T) {
	cfg := config.Default()
	cfg.Security = config.Security{UploadToken: "old", ReadToken: "old", AdminToken: "old"}
	r := New(cfg, &fake{})
	raw := testutil.Raw(time.Now().Add(-time.Minute))
	if w := call(r, "PUT", "/v1/snapshot", "unused-legacy-value", raw); w.Code != 200 {
		t.Fatal(w.Code)
	}
	for _, path := range []string{"/v1/snapshot", "/api/admin/me", "/api/admin/overview", "/api/admin/snapshots"} {
		for _, header := range []string{"", "invalid-legacy-value"} {
			if w := call(r, "GET", path, header, nil); w.Code != 200 {
				t.Fatalf("%s: %d", path, w.Code)
			}
		}
	}
	if w := call(r, "DELETE", "/v1/snapshot", "unused", nil); w.Code != 204 {
		t.Fatal(w.Code)
	}
}
func TestBodyValidationAndLimitsWithoutAuth(t *testing.T) {
	r := New(config.Default(), &fake{})
	if w := call(r, "PUT", "/v1/snapshot", "", []byte("invalid")); w.Code != 422 {
		t.Fatal(w.Code)
	}
	for _, length := range []int64{1, -1, MaxBody + 1} {
		q := httptest.NewRequest("PUT", "/v1/snapshot", strings.NewReader(strings.Repeat("x", MaxBody+1)))
		q.ContentLength = length
		q.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, q)
		if w.Code != 413 {
			t.Fatalf("limit bypass: %d", w.Code)
		}
	}
	raw := testutil.Raw(time.Now().Add(-time.Minute))
	for _, h := range []map[string]string{{"Content-Type": "text/plain"}, {"Content-Type": "application/json", "Content-Encoding": "gzip"}} {
		q := httptest.NewRequest("PUT", "/v1/snapshot", bytes.NewReader(raw))
		for key, value := range h {
			q.Header.Set(key, value)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, q)
		if w.Code != 415 {
			t.Fatal("invalid media type accepted", w.Code)
		}
	}
}
func TestDemoUnknownFieldsAndStaleSnapshotsRejected(t *testing.T) {
	r := New(config.Default(), &fake{})
	now := time.Now().Add(-time.Minute)
	raw := string(testutil.Raw(now))
	for _, bad := range []string{strings.Replace(raw, `"healthkit"`, `"demo"`, 1), strings.Replace(raw, `"schemaVersion":1`, `"token":"do-not-store","schemaVersion":1`, 1)} {
		w := call(r, "PUT", "/v1/snapshot", "", []byte(bad))
		if w.Code != 422 || strings.Contains(w.Body.String(), "do-not-store") {
			t.Fatal("invalid content accepted or echoed")
		}
	}
	if call(r, "PUT", "/v1/snapshot", "", []byte(raw)).Code != 200 {
		t.Fatal("initial upload failed")
	}
	if call(r, "PUT", "/v1/snapshot", "", testutil.Raw(now.Add(-time.Second))).Code != 409 {
		t.Fatal("stale data accepted")
	}
}
func TestBrowserOriginsStillChecked(t *testing.T) {
	r := New(config.Default(), &fake{})
	for _, tc := range []struct {
		method, path, origin string
		want                 int
	}{
		{"OPTIONS", "/v1/snapshot", "http://localhost:5173", 204},
		{"OPTIONS", "/v1/snapshot", "https://untrusted.example", 403},
		{"GET", "/v1/snapshot", "https://untrusted.example", 403},
		{"PUT", "/v1/snapshot", "https://untrusted.example", 403},
		{"DELETE", "/v1/snapshot", "https://untrusted.example", 403},
		{"GET", "/api/admin/overview", "https://untrusted.example", 403},
		{"GET", "/api/admin/overview", "http://example.com", 200},
	} {
		q := httptest.NewRequest(tc.method, tc.path, nil)
		q.Header.Set("Origin", tc.origin)
		if tc.method == "OPTIONS" {
			q.Header.Set("Access-Control-Request-Method", "PUT")
			q.Header.Set("Access-Control-Request-Headers", "content-type")
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, q)
		if w.Code != tc.want {
			t.Fatalf("%s %s origin=%s: got %d want %d", tc.method, tc.path, tc.origin, w.Code, tc.want)
		}
		if strings.HasPrefix(tc.path, "/api/admin/") && w.Header().Get("Access-Control-Allow-Origin") != "" {
			t.Fatal("admin CORS enabled")
		}
	}
}
