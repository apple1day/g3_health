package store

import (
	"context"
	"errors"
	"fmt"
	"github.com/apple1day/g3_health/backend/internal/history"
	"testing"
	"time"
)

func TestMySQLRawHistoryPagingRetryDeleteEpoch(t *testing.T) {
	s := testDB(t)
	ctx := context.Background()
	status, e := s.HistoryStatus(ctx)
	if e != nil {
		t.Fatal(e)
	}
	start := time.Date(2017, 3, 1, 20, 0, 0, 0, time.UTC)
	v := 60.0
	stage := 3
	b := history.Batch{SchemaVersion: 1, Epoch: status.Epoch, Kind: "sleep", Records: []history.Sample{}, DeletedIDs: []string{}}
	for i := 0; i < 120; i++ {
		b.Records = append(b.Records, history.Sample{ID: fmt.Sprintf("00000000-0000-4000-8000-%012d", i), Kind: "sleep", StartedAt: start, EndedAt: start.Add(time.Hour), Day: "2017-03-01", TimeZone: "UTC", SourceID: "watch", SourceName: "Watch", Unit: "min", Value: &v, Category: &stage, Metrics: map[string]float64{}})
	}
	if e = s.ApplyHistory(ctx, b); e != nil {
		t.Fatal(e)
	}
	if e = s.ApplyHistory(ctx, b); e != nil {
		t.Fatal(e)
	}
	status, e = s.HistoryStatus(ctx)
	if e != nil || status.Count != 120 {
		t.Fatal("retry duplicates", e, status.Count)
	}
	f := history.Filter{Kind: "sleep", Limit: 50}
	seen := map[string]bool{}
	for i := 0; i < 3; i++ {
		p, e := s.HistoryList(ctx, f)
		if e != nil {
			t.Fatal(e)
		}
		if p.Total != 120 {
			t.Fatal("wrong total")
		}
		for _, r := range p.Items {
			if seen[r.Sample.ID] {
				t.Fatal("duplicate at tied timestamp")
			}
			seen[r.Sample.ID] = true
		}
		f.BeforeNS, f.BeforeID, e = history.DecodeCursor(p.NextCursor)
		if e != nil {
			t.Fatal(e)
		}
	}
	if len(seen) != 120 {
		t.Fatal("dropped records", len(seen))
	}
	p, e := s.HistoryList(ctx, history.Filter{Kind: "sleep", From: "2018-01-01", Limit: 50})
	if e != nil || p.Total != 0 {
		t.Fatal("filter mismatch")
	}
	del := history.Batch{Epoch: status.Epoch, Kind: "sleep", DeletedIDs: []string{b.Records[0].ID}}
	if e = s.ApplyHistory(ctx, del); e != nil {
		t.Fatal(e)
	}
	vstatus, _ := s.HistoryStatus(ctx)
	if vstatus.Count != 119 {
		t.Fatal("deletion not applied")
	}
	if _, e = s.Latest(ctx); !errors.Is(e, ErrNotFound) {
		t.Fatal("archive changed snapshot")
	}
	if e = s.DeleteAll(ctx); e != nil {
		t.Fatal(e)
	}
	after, e := s.HistoryStatus(ctx)
	if e != nil || after.Epoch == status.Epoch || after.Count != 0 {
		t.Fatal("reset not atomic", e)
	}
	if e = s.ApplyHistory(ctx, b); !errors.Is(e, history.ErrEpoch) {
		t.Fatal("in-flight stale import recreated deleted data")
	}
}
