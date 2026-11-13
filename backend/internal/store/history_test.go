package store

import (
	"context"
	"errors"
	"fmt"
	"github.com/apple1day/g3_health/backend/internal/history"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestHistorySourceFilterUsesExactParameterizedComparison(t *testing.T) {
	source := "com.heytap.health' OR 1=1 --"
	q, args := historyWhere(history.Filter{Kind: "sleep", From: "2018-01-01", To: "2018-01-02", SourceID: source})
	if strings.Contains(q, source) || !strings.Contains(q, "AS BINARY)=CAST(? AS BINARY)") || !reflect.DeepEqual(args, []any{"sleep", "2018-01-01", "2018-01-02", source}) {
		t.Fatal("source must be an exact bound parameter", q, args)
	}
}

func TestMySQLHistorySourceInventoryAndPaging(t *testing.T) {
	s := testDB(t)
	ctx := context.Background()
	status, err := s.HistoryStatus(ctx)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Date(2018, 1, 1, 22, 0, 0, 0, time.UTC)
	value, stage := 60.0, 3
	batch := history.Batch{Epoch: status.Epoch, Kind: "sleep", Records: []history.Sample{}}
	for i := 0; i < 125; i++ {
		source, name := "com.heytap.health", "OPPO 健康"
		if i%2 == 0 {
			source, name = "com.apple.health", "Apple Watch"
		}
		batch.Records = append(batch.Records, history.Sample{ID: fmt.Sprintf("10000000-0000-4000-8000-%012d", i), Kind: "sleep", StartedAt: start, EndedAt: start.Add(time.Hour), Day: "2018-01-01", TimeZone: "UTC", SourceID: source, SourceName: name, Unit: "min", Value: &value, Category: &stage, Metrics: map[string]float64{}})
	}
	for i, source := range []string{"com.heytap.health ", "COM.HEYTAP.HEALTH", "foo' OR 1=1 --"} {
		r := batch.Records[0]
		r.ID = fmt.Sprintf("20000000-0000-4000-8000-%012d", i)
		r.SourceID, r.SourceName = source, "Distinct source"
		batch.Records = append(batch.Records, r)
	}
	old := batch.Records[1]
	old.ID = "30000000-0000-4000-8000-000000000000"
	old.StartedAt, old.EndedAt, old.Day = start.Add(-24*time.Hour), start.Add(-23*time.Hour), "2017-12-31"
	batch.Records = append(batch.Records, old)
	if err := s.ApplyHistory(ctx, batch); err != nil {
		t.Fatal(err)
	}
	filter := history.Filter{Kind: "sleep", From: "2018-01-01", To: "2018-01-01", SourceID: "com.heytap.health", Limit: 25}
	seen := map[string]bool{}
	for {
		page, err := s.HistoryList(ctx, filter)
		if err != nil {
			t.Fatal(err)
		}
		if page.Total != 62 || len(page.Sources) != 5 {
			t.Fatal("filter or full-range inventory mismatch", page.Total, page.Sources)
		}
		counts := map[string]int64{}
		for _, source := range page.Sources {
			counts[source.SourceID] = source.Count
			if source.SourceID == "com.heytap.health" && (source.SourceName != "OPPO 健康" || !source.Earliest.Equal(start) || !source.Latest.Equal(start.Add(time.Hour))) {
				t.Fatal("source coverage mismatch", source)
			}
		}
		if !reflect.DeepEqual(counts, map[string]int64{"com.heytap.health": 62, "com.apple.health": 63, "com.heytap.health ": 1, "COM.HEYTAP.HEALTH": 1, "foo' OR 1=1 --": 1}) {
			t.Fatal("inventory omitted a source or counted only the current page", counts)
		}
		for _, row := range page.Items {
			if row.Sample.SourceID != "com.heytap.health" || seen[row.Sample.ID] {
				t.Fatal("source leakage or duplicate page")
			}
			seen[row.Sample.ID] = true
		}
		if page.NextCursor == "" {
			break
		}
		filter.BeforeNS, filter.BeforeID, err = history.DecodeCursor(page.NextCursor)
		if err != nil {
			t.Fatal(err)
		}
	}
	if len(seen) != 62 {
		t.Fatal("source records lost during pagination", len(seen))
	}
	for _, source := range []string{"com.heytap.health ", "COM.HEYTAP.HEALTH", "foo' OR 1=1 --"} {
		page, err := s.HistoryList(ctx, history.Filter{Kind: "sleep", SourceID: source, Limit: 50})
		if err != nil || page.Total != 1 || len(page.Items) != 1 || page.Items[0].Sample.SourceID != source {
			t.Fatal("source comparison was not exact", source, err, page.Total)
		}
	}
	page, err := s.HistoryList(ctx, history.Filter{Kind: "sleep", SourceID: "missing", Limit: 50})
	if err != nil || page.Total != 0 || len(page.Items) != 0 || len(page.Sources) != 5 {
		t.Fatal("empty selection hid other available sources", err, page)
	}
	page, err = s.HistoryList(ctx, history.Filter{Kind: "heartRate", Limit: 50})
	if err != nil || len(page.Sources) != 0 || page.Sources == nil {
		t.Fatal("source inventory ignored kind filter", err, page)
	}
}

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
