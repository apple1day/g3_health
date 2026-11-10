package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"github.com/apple1day/g3_health/backend/internal/config"
	"github.com/apple1day/g3_health/backend/internal/snapshot"
	"github.com/apple1day/g3_health/backend/internal/store"
	"github.com/gin-gonic/gin"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const MaxBody = 128 * 1024

type Server struct {
	cfg          config.Config
	repo         store.Repository
	authFailures *limiter
}

func New(c config.Config, repo store.Repository) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	_ = r.SetTrustedProxies(nil)
	// Avoid Gin's default request/recovery logging: it may include credentials.
	r.Use(func(c *gin.Context) {
		defer func() {
			if recover() != nil {
				c.AbortWithStatusJSON(500, gin.H{"detail": "Internal server error."})
			}
		}()
		c.Next()
	})
	r.Use(func(c *gin.Context) {
		h := c.Writer.Header()
		h.Set("Cache-Control", "no-store")
		h.Set("Pragma", "no-cache")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		c.Next()
	})
	s := &Server{c, repo, &limiter{entries: map[string]failure{}}}
	r.Use(s.cors)
	r.GET("/healthz", func(c *gin.Context) {
		ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
		defer cancel()
		if repo.Ping(ctx) != nil {
			fail(c, 503, "Storage is temporarily unavailable.")
			return
		}
		c.JSON(200, gin.H{"status": "ok", "apiVersion": 1})
	})
	r.PUT("/v1/snapshot", s.auth(c.Security.UploadToken), s.put)
	r.GET("/v1/snapshot", s.auth(c.Security.ReadToken), s.latest)
	r.DELETE("/v1/snapshot", s.auth(c.Security.UploadToken), func(c *gin.Context) {
		if e := repo.DeleteAll(c.Request.Context()); e != nil {
			fail(c, 503, "Storage is temporarily unavailable.")
			return
		}
		c.Status(204)
	})
	admin := r.Group("/api/admin", s.auth(c.Security.AdminToken))
	admin.GET("/me", func(c *gin.Context) { c.JSON(200, gin.H{"role": "admin", "scope": "single-user-read-only"}) })
	admin.GET("/overview", func(c *gin.Context) {
		v, e := repo.Overview(c.Request.Context())
		if e != nil {
			fail(c, 503, "Storage is temporarily unavailable.")
			return
		}
		c.JSON(200, v)
	})
	admin.GET("/snapshots", func(c *gin.Context) {
		f, e := parseFilter(c, false)
		if e != nil {
			fail(c, 400, e.Error())
			return
		}
		v, e := repo.List(c.Request.Context(), f)
		if e != nil {
			fail(c, 503, "Storage is temporarily unavailable.")
			return
		}
		c.JSON(200, v)
	})
	admin.GET("/snapshots/:id", func(c *gin.Context) {
		id, e := strconv.ParseInt(c.Param("id"), 10, 64)
		if e != nil || id < 1 {
			fail(c, 400, "Invalid snapshot ID.")
			return
		}
		v, e := repo.Get(c.Request.Context(), id)
		if errors.Is(e, store.ErrNotFound) {
			fail(c, 404, "Snapshot not found.")
			return
		}
		if e != nil {
			fail(c, 503, "Storage is temporarily unavailable.")
			return
		}
		c.JSON(200, v)
	})
	admin.GET("/days", func(c *gin.Context) {
		f, e := parseFilter(c, true)
		if e != nil {
			fail(c, 400, e.Error())
			return
		}
		v, e := repo.Days(c.Request.Context(), f)
		if e != nil {
			fail(c, 503, "Storage is temporarily unavailable.")
			return
		}
		c.JSON(200, gin.H{"items": v, "aggregation": "last-snapshot-per-local-day"})
	})
	index := func(c *gin.Context) {
		file := filepath.Join(s.cfg.Server.AdminDist, "index.html")
		if _, e := os.Stat(file); e != nil {
			fail(c, 503, "Admin UI not built. Run bash setup-backend.sh.")
			return
		}
		c.File(file)
	}
	r.GET("/", func(c *gin.Context) { c.Redirect(http.StatusTemporaryRedirect, "/admin/") })
	r.GET("/admin", func(c *gin.Context) { c.Redirect(http.StatusTemporaryRedirect, "/admin/") })
	r.GET("/admin/", index)
	r.Static("/admin/assets", filepath.Join(c.Server.AdminDist, "assets"))
	r.NoRoute(func(c *gin.Context) { fail(c, 404, "Not found.") })
	return r
}
func fail(c *gin.Context, status int, message string) {
	c.AbortWithStatusJSON(status, gin.H{"detail": message})
}
func (s *Server) auth(expected string) gin.HandlerFunc {
	return func(c *gin.Context) {
		headers := c.Request.Header.Values("Authorization")
		supplied := ""
		if len(headers) == 1 {
			parts := strings.Split(headers[0], " ")
			if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
				supplied = parts[1]
			}
		}
		want, got := sha256.Sum256([]byte(expected)), sha256.Sum256([]byte(supplied))
		if supplied != "" && len(supplied) <= 514 && subtle.ConstantTimeCompare(want[:], got[:]) == 1 {
			c.Next()
			return
		}
		// Failed attempts only, per actual peer IP; never trust user-supplied XFF.
		if !s.authFailures.allow(c.ClientIP(), time.Now()) {
			c.Header("Retry-After", "60")
			fail(c, 429, "Too many invalid authentication attempts.")
			return
		}
		c.Header("WWW-Authenticate", "Bearer")
		fail(c, 401, "A valid scoped bearer token is required.")
	}
}
func (s *Server) cors(c *gin.Context) {
	// Admin is SAME-ORIGIN only; Even/iPhone compatibility is limited to /v1.
	if !strings.HasPrefix(c.Request.URL.Path, "/v1/") {
		c.Next()
		return
	}
	origin := c.GetHeader("Origin")
	allowed := ""
	for _, o := range s.cfg.Server.AllowedOrigins {
		if o == "*" {
			allowed = "*"
			break
		}
		if o == origin {
			allowed = origin
		}
	}
	if origin != "" && allowed != "" {
		c.Header("Access-Control-Allow-Origin", allowed)
		c.Header("Vary", "Origin")
	}
	if c.Request.Method == http.MethodOptions {
		method := c.GetHeader("Access-Control-Request-Method")
		if allowed == "" || (method != "GET" && method != "PUT" && method != "DELETE") {
			fail(c, 403, "Origin or method not allowed.")
			return
		}
		for _, h := range strings.Split(c.GetHeader("Access-Control-Request-Headers"), ",") {
			h = strings.ToLower(strings.TrimSpace(h))
			if h != "" && h != "authorization" && h != "content-type" {
				fail(c, 403, "Header not allowed.")
				return
			}
		}
		c.Header("Access-Control-Allow-Methods", "GET, PUT, DELETE")
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type")
		c.Header("Access-Control-Max-Age", "600")
		c.AbortWithStatus(204)
		return
	}
	c.Next()
}
func (s *Server) put(c *gin.Context) {
	contentType, _, e := mime.ParseMediaType(c.GetHeader("Content-Type"))
	if e != nil || contentType != "application/json" {
		fail(c, 415, "Content-Type must be application/json.")
		return
	}
	enc := c.GetHeader("Content-Encoding")
	if enc != "" && !strings.EqualFold(enc, "identity") {
		fail(c, 415, "Compressed request bodies are not accepted.")
		return
	}
	if c.Request.ContentLength > MaxBody {
		fail(c, 413, "Snapshot exceeds the 128 KiB limit.")
		return
	}
	body := http.MaxBytesReader(c.Writer, c.Request.Body, MaxBody)
	defer body.Close()
	raw, e := io.ReadAll(body)
	if e != nil {
		var size *http.MaxBytesError
		if errors.As(e, &size) {
			fail(c, 413, "Snapshot exceeds the 128 KiB limit.")
		} else {
			fail(c, 400, "Cannot read snapshot body.")
		}
		return
	}
	cfg := s.cfg.Security
	v, e := snapshot.Parse(raw, time.Now(), cfg.UploadToken, cfg.ReadToken, cfg.AdminToken)
	if e != nil {
		fail(c, 422, "Invalid snapshot. Check schema v1, timestamps, units, field types, and dataMode=healthkit.")
		return
	}
	received, e := s.repo.Put(c.Request.Context(), v)
	if errors.Is(e, store.ErrConflict) {
		fail(c, 409, "An equal or newer snapshot is already stored. Refresh on the phone before retrying.")
		return
	}
	if e != nil {
		fail(c, 503, "Storage is temporarily unavailable.")
		return
	}
	c.JSON(200, gin.H{"receivedAt": received})
}
func (s *Server) latest(c *gin.Context) {
	v, e := s.repo.Latest(c.Request.Context())
	if errors.Is(e, store.ErrNotFound) {
		fail(c, 404, "No health snapshot has been uploaded yet.")
		return
	}
	if e != nil {
		fail(c, 503, "Storage is temporarily unavailable.")
		return
	}
	c.JSON(200, gin.H{"snapshot": v.Snapshot, "receivedAt": v.ReceivedAt})
}
func parseFilter(c *gin.Context, daily bool) (store.Filter, error) {
	f := store.Filter{From: c.Query("from"), To: c.Query("to"), Page: 1, PageSize: 20}
	for _, d := range []string{f.From, f.To} {
		if d != "" {
			t, e := time.Parse("2006-01-02", d)
			if e != nil || t.Format("2006-01-02") != d {
				return f, errors.New("Dates must use YYYY-MM-DD.")
			}
		}
	}
	if f.From != "" && f.To != "" && f.From > f.To {
		return f, errors.New("from must not be later than to.")
	}
	for key, p := range map[string]*int{"page": &f.Page, "pageSize": &f.PageSize} {
		if v := c.Query(key); v != "" {
			n, e := strconv.Atoi(v)
			if e != nil {
				return f, errors.New("Invalid pagination.")
			}
			*p = n
		}
	}
	if f.Page < 1 || f.Page > 1000000 || f.PageSize < 1 || f.PageSize > 100 {
		return f, errors.New("page >=1 and pageSize 1..100 required.")
	}
	if daily {
		if f.From == "" || f.To == "" {
			return f, errors.New("Daily queries require from and to.")
		}
		a, _ := time.Parse("2006-01-02", f.From)
		b, _ := time.Parse("2006-01-02", f.To)
		if b.Sub(a) > 365*24*time.Hour {
			return f, errors.New("Daily range may contain at most 366 days.")
		}
	}
	return f, nil
}

type failure struct {
	start time.Time
	count int
}
type limiter struct {
	mu      sync.Mutex
	entries map[string]failure
}

func (l *limiter) allow(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.entries) > 2048 {
		for k, v := range l.entries {
			if now.Sub(v.start) > time.Minute {
				delete(l.entries, k)
			}
		}
		if len(l.entries) > 2048 {
			return false
		}
	}
	f := l.entries[ip]
	if now.Sub(f.start) > time.Minute {
		f = failure{start: now}
	}
	f.count++
	l.entries[ip] = f
	return f.count <= 30
}
