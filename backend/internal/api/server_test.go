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
func configForTest() config.Config {
	c := config.Default()
	c.Security = config.Security{UploadToken: strings.Repeat("u", 43), ReadToken: strings.Repeat("r", 43), AdminToken: strings.Repeat("a", 43)}
	return c
}
func call(r http.Handler, method, path, token string, body []byte) *httptest.ResponseRecorder {
	q := httptest.NewRequest(method, path, bytes.NewReader(body))
	q.Header.Set("Content-Type", "application/json")
	if token != "" {
		q.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, q)
	return w
}
func TestRolesAndLifecycle(t *testing.T) {
	cfg := configForTest()
	f := &fake{}
	r := New(cfg, f)
	raw := testutil.Raw(time.Now().Add(-time.Minute))
	cases := []struct {
		method, path, token string
		body                []byte
		want                int
	}{
		{"GET", "/healthz", "", nil, 200}, {"GET", "/v1/snapshot", cfg.Security.ReadToken, nil, 404},
		{"PUT", "/v1/snapshot", cfg.Security.ReadToken, raw, 401}, {"PUT", "/v1/snapshot", cfg.Security.AdminToken, raw, 401},
		{"GET", "/api/admin/me", cfg.Security.UploadToken, nil, 401}, {"GET", "/api/admin/me", cfg.Security.ReadToken, nil, 401}, {"GET", "/api/admin/me", cfg.Security.AdminToken, nil, 200},
		{"PUT", "/v1/snapshot", cfg.Security.UploadToken, raw, 200}, {"PUT", "/v1/snapshot", cfg.Security.UploadToken, raw, 200},
		{"GET", "/v1/snapshot", cfg.Security.ReadToken, nil, 200}, {"GET", "/v1/snapshot", cfg.Security.UploadToken, nil, 401},
		{"GET", "/api/admin/overview", cfg.Security.AdminToken, nil, 200}, {"GET", "/api/admin/snapshots?page=0", cfg.Security.AdminToken, nil, 400},
		{"GET", "/api/admin/days?from=2025-01-01&to=2026-12-01", cfg.Security.AdminToken, nil, 400},
		{"GET", "/api/admin/days", cfg.Security.AdminToken, nil, 400},
		{"GET", "/api/admin/snapshots/1", cfg.Security.AdminToken, nil, 200},
		{"DELETE", "/v1/snapshot", cfg.Security.ReadToken, nil, 401}, {"DELETE", "/v1/snapshot", cfg.Security.UploadToken, nil, 204}, {"DELETE", "/v1/snapshot", cfg.Security.UploadToken, nil, 204},
		{"GET", "/v1/snapshot", cfg.Security.ReadToken, nil, 404},
	}
	for _, c := range cases {
		w := call(r, c.method, c.path, c.token, c.body)
		if w.Code != c.want {
			t.Fatalf("%s %s: got %d want %d: %s", c.method, c.path, w.Code, c.want, w.Body.String())
		}
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("missing private response policy")
		}
	}
}
func TestAuthenticationBeforeBodyAndLimits(t *testing.T) {
	cfg := configForTest()
	r := New(cfg, &fake{})
	if w := call(r, "PUT", "/v1/snapshot", "", []byte("invalid")); w.Code != 401 {
		t.Fatal(w.Code)
	}
	for _, length := range []int64{1, -1, MaxBody + 1} {
		q := httptest.NewRequest("PUT", "/v1/snapshot", strings.NewReader(strings.Repeat("x", MaxBody+1)))
		q.ContentLength = length
		q.Header.Set("Authorization", "Bearer "+cfg.Security.UploadToken)
		q.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, q)
		if w.Code != 413 {
			t.Fatalf("limit bypass: %d", w.Code)
		}
	}
	q := httptest.NewRequest("GET", "/v1/snapshot", nil)
	q.Header.Add("Authorization", "Bearer "+cfg.Security.ReadToken)
	q.Header.Add("Authorization", "Bearer "+cfg.Security.ReadToken)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, q)
	if w.Code != 401 {
		t.Fatal("duplicate auth accepted")
	}
}
func TestDemoAndSecretsRejected(t *testing.T) {
	cfg := configForTest()
	r := New(cfg, &fake{})
	raw := string(testutil.Raw(time.Now().Add(-time.Minute)))
	for _, b := range []string{strings.Replace(raw, `"healthkit"`, `"demo"`, 1), strings.Replace(raw, `"warnings":[]`, `"warnings":["`+cfg.Security.UploadToken+`"]`, 1)} {
		w := call(r, "PUT", "/v1/snapshot", cfg.Security.UploadToken, []byte(b))
		if w.Code != 422 || strings.Contains(w.Body.String(), cfg.Security.UploadToken) {
			t.Fatal("invalid or sensitive content accepted/echoed")
		}
	}
}
func TestCORSAndAdminIsolation(t *testing.T) {
	cfg := configForTest()
	r := New(cfg, &fake{})
	for _, allowed := range []bool{true, false} {
		q := httptest.NewRequest("OPTIONS", "/v1/snapshot", nil)
		origin := "http://localhost:5173"
		want := 204
		if !allowed {
			origin = "https://untrusted.example"
			want = 403
		}
		q.Header.Set("Origin", origin)
		q.Header.Set("Access-Control-Request-Method", "PUT")
		q.Header.Set("Access-Control-Request-Headers", "authorization,content-type")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, q)
		if w.Code != want {
			t.Fatal(w.Code)
		}
	}
	q := httptest.NewRequest("GET", "/api/admin/me", nil)
	q.Header.Set("Authorization", "Bearer "+cfg.Security.AdminToken)
	q.Header.Set("Origin", "http://localhost:5173")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, q)
	if w.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("admin exposed cross-origin")
	}
}
