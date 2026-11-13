package api

import (
	"context"
	"errors"
	"github.com/apple1day/g3_health/backend/internal/history"
	"github.com/apple1day/g3_health/backend/internal/store"
	"github.com/gin-gonic/gin"
	"io"
	"mime"
	"net/http"
	"strconv"
	"time"
)

func (s *Server) historyRoutes(r *gin.Engine) {
	repo, ok := s.repo.(store.HistoryRepository)
	unavailable := func(c *gin.Context) bool {
		if !ok {
			fail(c, 503, "History storage is unavailable. Update and initialize the Gin backend.")
			return true
		}
		return false
	}
	status := func(c *gin.Context) {
		if unavailable(c) {
			return
		}
		ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
		defer cancel()
		v, e := repo.HistoryStatus(ctx)
		if e != nil {
			fail(c, 503, "History storage is unavailable.")
			return
		}
		c.JSON(200, v)
	}
	list := func(c *gin.Context) {
		if unavailable(c) {
			return
		}
		f := history.Filter{Kind: c.Query("kind"), From: c.Query("from"), To: c.Query("to"), SourceID: c.Query("sourceID"), Limit: 50}
		if f.Kind != "" && !history.ValidKind(f.Kind) || f.From != "" && !history.ValidDay(f.From) || f.To != "" && !history.ValidDay(f.To) || f.From != "" && f.To != "" && f.From > f.To || !history.ValidSourceID(f.SourceID) {
			fail(c, 400, "Invalid history filter.")
			return
		}
		var e error
		if q := c.Query("limit"); q != "" {
			f.Limit, e = strconv.Atoi(q)
		}
		if e != nil || f.Limit < 1 || f.Limit > 100 {
			fail(c, 400, "History page limit must be 1..100.")
			return
		}
		f.BeforeNS, f.BeforeID, e = history.DecodeCursor(c.Query("cursor"))
		if e != nil {
			fail(c, 400, "Invalid history cursor.")
			return
		}
		ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
		defer cancel()
		v, e := repo.HistoryList(ctx, f)
		if e != nil {
			fail(c, 503, "History storage is unavailable.")
			return
		}
		c.JSON(200, v)
	}
	r.GET("/v1/history/status", status)
	r.GET("/v1/history/records", list)
	r.GET("/api/admin/records/status", status)
	r.GET("/api/admin/records", list)
	r.PUT("/v1/history/batch", func(c *gin.Context) {
		if unavailable(c) {
			return
		}
		media, _, e := mime.ParseMediaType(c.GetHeader("Content-Type"))
		enc := c.GetHeader("Content-Encoding")
		if e != nil || media != "application/json" || (enc != "" && enc != "identity") {
			fail(c, 415, "History batches require uncompressed application/json.")
			return
		}
		const limit = 1024 * 1024
		if c.Request.ContentLength > limit {
			fail(c, 413, "History batch exceeds 1 MiB.")
			return
		}
		body := http.MaxBytesReader(c.Writer, c.Request.Body, limit)
		defer body.Close()
		raw, e := io.ReadAll(body)
		if e != nil {
			var tooBig *http.MaxBytesError
			if errors.As(e, &tooBig) {
				fail(c, 413, "History batch exceeds 1 MiB.")
			} else {
				fail(c, 400, "Cannot read history batch.")
			}
			return
		}
		b, e := history.Parse(raw, time.Now())
		if e != nil {
			fail(c, 422, "Invalid history batch. Check version, kind, IDs, timestamps and the 200-record limit.")
			return
		}
		ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
		defer cancel()
		e = repo.ApplyHistory(ctx, b)
		if errors.Is(e, history.ErrEpoch) {
			fail(c, 409, "History store was reset. Start synchronization again.")
			return
		}
		if e != nil {
			fail(c, 503, "History storage is unavailable.")
			return
		}
		c.JSON(200, gin.H{"accepted": len(b.Records), "deleted": len(b.DeletedIDs), "epoch": b.Epoch})
	})
}
