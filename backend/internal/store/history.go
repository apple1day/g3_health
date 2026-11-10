package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"fmt"
	"github.com/apple1day/g3_health/backend/internal/history"
	"strings"
	"time"
)

type HistoryRepository interface {
	HistoryStatus(context.Context) (history.Status, error)
	ApplyHistory(context.Context, history.Batch) error
	HistoryList(context.Context, history.Filter) (history.Page, error)
}

func (s *MySQL) recordsTable() string {
	return strings.Replace(s.table, "health_snapshots`", "health_records`", 1)
}
func (s *MySQL) historyState() string {
	return strings.Replace(s.state, "health_state`", "health_history_state`", 1)
}
func newEpoch() (string, error) {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		return "", e
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}
func (s *MySQL) migrateHistory(ctx context.Context) error {
	epoch, e := newEpoch()
	if e != nil {
		return e
	}
	queries := []string{
		"CREATE TABLE IF NOT EXISTS " + s.recordsTable() + ` (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, kind VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL, external_id VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL, started_ns BIGINT NOT NULL, ended_ns BIGINT NOT NULL, local_day CHAR(10) NOT NULL, received_ns BIGINT NOT NULL, payload JSON NOT NULL, UNIQUE KEY uq_kind_uuid(kind,external_id), KEY idx_start_id(started_ns,id), KEY idx_kind_start(kind,started_ns,id), KEY idx_local_day(local_day,kind)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
		"CREATE TABLE IF NOT EXISTS " + s.historyState() + " (id TINYINT NOT NULL PRIMARY KEY, epoch CHAR(36) NOT NULL) ENGINE=InnoDB",
	}
	for _, q := range queries {
		if _, e = s.DB.ExecContext(ctx, q); e != nil {
			return e
		}
	}
	_, e = s.DB.ExecContext(ctx, "INSERT IGNORE INTO "+s.historyState()+" (id,epoch) VALUES(1,?)", epoch)
	return e
}
func (s *MySQL) HistoryStatus(ctx context.Context) (history.Status, error) {
	v := history.Status{Counts: map[string]int64{}}
	tx, e := s.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true, Isolation: sql.LevelRepeatableRead})
	if e != nil {
		return v, e
	}
	defer tx.Rollback()
	if e = tx.QueryRowContext(ctx, "SELECT epoch FROM "+s.historyState()+" WHERE id=1").Scan(&v.Epoch); e != nil {
		return v, e
	}
	rows, e := tx.QueryContext(ctx, "SELECT kind,COUNT(*),MIN(started_ns),MAX(ended_ns) FROM "+s.recordsTable()+" GROUP BY kind")
	if e != nil {
		return v, e
	}
	for rows.Next() {
		var kind string
		var n, a, b int64
		if e = rows.Scan(&kind, &n, &a, &b); e != nil {
			rows.Close()
			return v, e
		}
		v.Counts[kind] = n
		v.Count += n
		start, end := time.Unix(0, a).UTC(), time.Unix(0, b).UTC()
		if v.Earliest == nil || start.Before(*v.Earliest) {
			v.Earliest = &start
		}
		if v.Latest == nil || end.After(*v.Latest) {
			v.Latest = &end
		}
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return v, e
	}
	return v, tx.Commit()
}
func (s *MySQL) ApplyHistory(ctx context.Context, b history.Batch) error {
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	var epoch string
	if e = tx.QueryRowContext(ctx, "SELECT epoch FROM "+s.historyState()+" WHERE id=1 FOR UPDATE").Scan(&epoch); e != nil {
		return e
	}
	if b.Epoch != epoch {
		return history.ErrEpoch
	}
	for _, r := range b.Records {
		raw, e := json.Marshal(r)
		if e != nil {
			return e
		}
		// UUID identity preserves retries and changes without adding duplicated sensor samples.
		_, e = tx.ExecContext(ctx, "INSERT INTO "+s.recordsTable()+" (kind,external_id,started_ns,ended_ns,local_day,received_ns,payload) VALUES (?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE started_ns=VALUES(started_ns),ended_ns=VALUES(ended_ns),local_day=VALUES(local_day),received_ns=VALUES(received_ns),payload=VALUES(payload)", r.Kind, r.ID, r.StartedAt.UnixNano(), r.EndedAt.UnixNano(), r.Day, time.Now().UnixNano(), string(raw))
		if e != nil {
			return e
		}
	}
	for _, id := range b.DeletedIDs {
		if _, e = tx.ExecContext(ctx, "DELETE FROM "+s.recordsTable()+" WHERE kind=? AND external_id=?", b.Kind, id); e != nil {
			return e
		}
	}
	return tx.Commit()
}
func historyWhere(f history.Filter) (string, []any) {
	q := " WHERE 1=1"
	a := []any{}
	if f.Kind != "" {
		q += " AND kind=?"
		a = append(a, f.Kind)
	}
	if f.From != "" {
		q += " AND local_day>=?"
		a = append(a, f.From)
	}
	if f.To != "" {
		q += " AND local_day<=?"
		a = append(a, f.To)
	}
	return q, a
}
func (s *MySQL) HistoryList(ctx context.Context, f history.Filter) (history.Page, error) {
	p := history.Page{Items: []history.Row{}}
	q, a := historyWhere(f)
	tx, e := s.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true, Isolation: sql.LevelRepeatableRead})
	if e != nil {
		return p, e
	}
	defer tx.Rollback()
	if e = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+s.recordsTable()+q, a...).Scan(&p.Total); e != nil {
		return p, e
	}
	if f.BeforeID > 0 {
		q += " AND (started_ns<? OR (started_ns=? AND id<?))"
		a = append(a, f.BeforeNS, f.BeforeNS, f.BeforeID)
	}
	a = append(a, f.Limit+1)
	rows, e := tx.QueryContext(ctx, "SELECT id,payload,received_ns FROM "+s.recordsTable()+q+" ORDER BY started_ns DESC,id DESC LIMIT ?", a...)
	if e != nil {
		return p, e
	}
	for rows.Next() {
		var r history.Row
		var raw []byte
		var ns int64
		if e = rows.Scan(&r.ID, &raw, &ns); e != nil {
			rows.Close()
			return p, e
		}
		if e = json.Unmarshal(raw, &r.Sample); e != nil {
			rows.Close()
			return p, e
		}
		r.ReceivedAt = time.Unix(0, ns).UTC()
		p.Items = append(p.Items, r)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return p, e
	}
	if len(p.Items) > f.Limit {
		p.Items = p.Items[:f.Limit]
		last := p.Items[len(p.Items)-1]
		p.NextCursor = history.Cursor(last.Sample.StartedAt.UnixNano(), last.ID)
	}
	return p, tx.Commit()
}

// Called in the same transaction as deleting the legacy snapshot history.
func (s *MySQL) deleteHistory(ctx context.Context, tx *sql.Tx) error {
	var old string
	if e := tx.QueryRowContext(ctx, "SELECT epoch FROM "+s.historyState()+" WHERE id=1 FOR UPDATE").Scan(&old); e != nil {
		return e
	}
	epoch, e := newEpoch()
	if e != nil {
		return e
	}
	if _, e = tx.ExecContext(ctx, "DELETE FROM "+s.recordsTable()); e != nil {
		return e
	}
	_, e = tx.ExecContext(ctx, "UPDATE "+s.historyState()+" SET epoch=? WHERE id=1", epoch)
	return e
}
