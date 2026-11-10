package api

import (
	"context"
	"errors"
	"github.com/apple1day/g3_health/backend/internal/config"
	"github.com/apple1day/g3_health/backend/internal/snapshot"
	"github.com/apple1day/g3_health/backend/internal/store"
	"github.com/gin-gonic/gin"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const MaxBody = 128 * 1024

type Server struct {
	cfg  config.Config
	repo store.Repository
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
	s := &Server{cfg: c, repo: repo}
	r.Use(s.cors)
	s.historyRoutes(r)
	r.GET("/healthz", func(c *gin.Context) {
		ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
		defer cancel()
		if repo.Ping(ctx) != nil {
			fail(c, 503, "Storage is temporarily unavailable.")
			return
		}
		c.JSON(200, gin.H{"status": "ok", "apiVersion": 1})
	})
	r.PUT("/v1/snapshot", s.put)
	r.GET("/v1/snapshot", s.latest)
	r.DELETE("/v1/snapshot", func(c *gin.Context) {
		if e := repo.DeleteAll(c.Request.Context()); e != nil {
			fail(c, 503, "Storage is temporarily unavailable.")
			return
		}
		c.Status(204)
	})
	admin := r.Group("/api/admin")
	admin.GET("/me", func(c *gin.Context) {
		c.JSON(200, gin.H{"authMode": "none", "scope": "local-single-user", "warning": "No authentication. Trusted LAN only."})
	})
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
func (s *Server) cors(c *gin.Context) {
	// Browser-origin restrictions are NOT identity authentication. Native clients
	// with no Origin can access every route; keep this service on a trusted LAN.
	origin := c.GetHeader("Origin")
	sameOrigin := false
	if u, err := url.Parse(origin); err == nil && origin != "" {
		scheme := "http"
		if c.Request.TLS != nil {
			scheme = "https"
		}
		sameOrigin = u.Scheme == scheme && u.Host == c.Request.Host && u.User == nil && u.Path == "" && u.RawQuery == "" && u.Fragment == ""
	}
	if !strings.HasPrefix(c.Request.URL.Path, "/v1/") {
		if strings.HasPrefix(c.Request.URL.Path, "/api/admin/") &&
			((origin != "" && !sameOrigin) || c.GetHeader("Sec-Fetch-Site") == "cross-site") {
			fail(c, 403, "Admin browser requests must be same-origin.")
			return
		}
		c.Next()
		return
	}
	allowed := ""
	if sameOrigin {
		allowed = origin
	}
	for _, o := range s.cfg.Server.AllowedOrigins {
		if o == "*" && origin != "" {
			allowed = "*"
			break
		}
		if o == origin {
			allowed = origin
		}
	}
	if origin != "" && allowed == "" {
		fail(c, 403, "Origin not allowed.")
		return
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
	// The service is deliberately unauthenticated; retain strict payload validation.
	v, e := snapshot.Parse(raw, time.Now())
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
