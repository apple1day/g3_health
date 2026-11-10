package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/apple1day/g3_health/backend/internal/config"
	"github.com/apple1day/g3_health/backend/internal/snapshot"
	"github.com/go-sql-driver/mysql"
	"time"
)

type MySQL struct {
	DB           *sql.DB
	table, state string
}

func open(c config.Config, withoutDatabase bool) (*sql.DB, error) {
	m, e := c.DriverConfig(withoutDatabase)
	if e != nil {
		return nil, e
	}
	connector, e := mysql.NewConnector(m)
	if e != nil {
		return nil, errors.New("MySQL 连接参数不正确")
	}
	db := sql.OpenDB(connector)
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(3 * time.Minute)
	db.SetConnMaxIdleTime(time.Minute)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if e = db.PingContext(ctx); e != nil {
		db.Close()
		return nil, errors.New("无法连接 MySQL：请检查服务、地址、密码、数据库和权限（未输出连接凭据）")
	}
	return db, nil
}
func New(c config.Config) (*MySQL, error) {
	if e := c.Validate(); e != nil {
		return nil, e
	}
	db, e := open(c, false)
	if e != nil {
		return nil, e
	}
	return &MySQL{db, "`" + c.MySQL.Prefix + "health_snapshots`", "`" + c.MySQL.Prefix + "health_state`"}, nil
}

// Migrate is additive and idempotent; no DROP / destructive schema rewrite.
func Migrate(ctx context.Context, c config.Config, createDatabase bool) error {
	if e := c.Validate(); e != nil {
		return e
	}
	if createDatabase {
		db, e := open(c, true)
		if e != nil {
			return e
		}
		_, e = db.ExecContext(ctx, "CREATE DATABASE IF NOT EXISTS `"+c.MySQL.DBName+"` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
		db.Close()
		if e != nil {
			return errors.New("无法创建数据库，请先手动创建 g3_health 或检查建库权限")
		}
	}
	s, e := New(c)
	if e != nil {
		return e
	}
	defer s.DB.Close()
	statements := []string{
		`CREATE TABLE IF NOT EXISTS ` + s.table + ` (
   id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
   generated_ns BIGINT NOT NULL,
   received_ns BIGINT NOT NULL,
   local_day CHAR(10) NOT NULL,
   time_zone VARCHAR(80) NOT NULL,
   digest CHAR(64) NOT NULL,
   steps DOUBLE NULL,
   sleep_minutes DOUBLE NULL,
   active_energy_kcal DOUBLE NULL,
   heart_rate_bpm DOUBLE NULL,
   payload JSON NOT NULL,
   UNIQUE KEY uq_generated (generated_ns),
   KEY idx_day_generated (local_day,generated_ns)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
		`CREATE TABLE IF NOT EXISTS ` + s.state + ` (id TINYINT NOT NULL PRIMARY KEY, latest_id BIGINT NULL, schema_version INT NOT NULL DEFAULT 1) ENGINE=InnoDB`,
		`INSERT IGNORE INTO ` + s.state + ` (id,latest_id,schema_version) VALUES (1,NULL,1)`,
	}
	for _, q := range statements {
		if _, e = s.DB.ExecContext(ctx, q); e != nil {
			return errors.New("数据库表初始化失败，请检查 MySQL 8.0+ 版本和 CREATE/ALTER 权限")
		}
	}
	return nil
}
func (s *MySQL) Ping(ctx context.Context) error { return s.DB.PingContext(ctx) }
func (s *MySQL) Put(ctx context.Context, v snapshot.Snapshot) (time.Time, error) {
	payload, e := json.Marshal(v)
	if e != nil {
		return time.Time{}, e
	}
	hash := sha256.Sum256(payload)
	digest := hex.EncodeToString(hash[:])
	ns := v.GeneratedAt.UnixNano()
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return time.Time{}, e
	}
	defer tx.Rollback()
	// A permanent singleton row serializes writers, INCLUDING first upload/delete.
	var current sql.NullInt64
	if e = tx.QueryRowContext(ctx, "SELECT latest_id FROM "+s.state+" WHERE id=1 FOR UPDATE").Scan(&current); e != nil {
		return time.Time{}, e
	}
	if current.Valid {
		var oldNS, received int64
		var oldDigest string
		if e = tx.QueryRowContext(ctx, "SELECT generated_ns,received_ns,digest FROM "+s.table+" WHERE id=?", current.Int64).Scan(&oldNS, &received, &oldDigest); e != nil {
			return time.Time{}, e
		}
		if ns < oldNS {
			return time.Time{}, ErrConflict
		}
		if ns == oldNS {
			if digest != oldDigest {
				return time.Time{}, ErrConflict
			}
			return time.Unix(0, received).UTC(), nil
		}
	}
	receipt := time.Now().UTC()
	res, e := tx.ExecContext(ctx, "INSERT INTO "+s.table+" (generated_ns,received_ns,local_day,time_zone,digest,steps,sleep_minutes,active_energy_kcal,heart_rate_bpm,payload) VALUES (?,?,?,?,?,?,?,?,?,?)", ns, receipt.UnixNano(), v.Day, v.TimeZone, digest, v.Activity.Steps, v.Sleep.TotalMinutes, v.Activity.ActiveEnergyKcal, v.HeartRate.BPM, string(payload))
	if e != nil {
		return time.Time{}, e
	}
	id, e := res.LastInsertId()
	if e != nil {
		return time.Time{}, e
	}
	if _, e = tx.ExecContext(ctx, "UPDATE "+s.state+" SET latest_id=? WHERE id=1", id); e != nil {
		return time.Time{}, e
	}
	if e = tx.Commit(); e != nil {
		return time.Time{}, e
	}
	return receipt, nil
}

type scanner interface{ Scan(...any) error }

func scanRecord(row scanner) (Record, error) {
	var r Record
	var raw []byte
	var ns int64
	e := row.Scan(&r.ID, &raw, &ns)
	if errors.Is(e, sql.ErrNoRows) {
		return r, ErrNotFound
	}
	if e != nil {
		return r, e
	}
	if e = json.Unmarshal(raw, &r.Snapshot); e != nil {
		return r, e
	}
	r.ReceivedAt = time.Unix(0, ns).UTC()
	return r, nil
}
func (s *MySQL) Latest(ctx context.Context) (Record, error) {
	return scanRecord(s.DB.QueryRowContext(ctx, "SELECT s.id,s.payload,s.received_ns FROM "+s.table+" s JOIN "+s.state+" st ON s.id=st.latest_id WHERE st.id=1"))
}
func (s *MySQL) Get(ctx context.Context, id int64) (Record, error) {
	return scanRecord(s.DB.QueryRowContext(ctx, "SELECT id,payload,received_ns FROM "+s.table+" WHERE id=?", id))
}
func (s *MySQL) DeleteAll(ctx context.Context) error {
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	var id sql.NullInt64
	if e = tx.QueryRowContext(ctx, "SELECT latest_id FROM "+s.state+" WHERE id=1 FOR UPDATE").Scan(&id); e != nil {
		return e
	}
	if _, e = tx.ExecContext(ctx, "UPDATE "+s.state+" SET latest_id=NULL WHERE id=1"); e != nil {
		return e
	}
	if _, e = tx.ExecContext(ctx, "DELETE FROM "+s.table); e != nil {
		return e
	}
	return tx.Commit()
}
func (s *MySQL) Overview(ctx context.Context) (Overview, error) {
	var v Overview
	var first, last sql.NullString
	e := s.DB.QueryRowContext(ctx, "SELECT COUNT(*),COUNT(DISTINCT local_day),MIN(local_day),MAX(local_day) FROM "+s.table).Scan(&v.Count, &v.DayCount, &first, &last)
	if e != nil {
		return v, e
	}
	if first.Valid {
		v.FirstDay = &first.String
	}
	if last.Valid {
		v.LastDay = &last.String
	}
	r, e := s.Latest(ctx)
	if e == nil {
		v.Latest = &r
	} else if !errors.Is(e, ErrNotFound) {
		return v, e
	}
	return v, nil
}
func filterSQL(f Filter) (string, []any) {
	q := " WHERE 1=1"
	args := []any{}
	if f.From != "" {
		q += " AND local_day>=?"
		args = append(args, f.From)
	}
	if f.To != "" {
		q += " AND local_day<=?"
		args = append(args, f.To)
	}
	return q, args
}
func (s *MySQL) List(ctx context.Context, f Filter) (Page, error) {
	p := Page{Items: []Record{}, Page: f.Page, PageSize: f.PageSize}
	q, args := filterSQL(f)
	if e := s.DB.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+s.table+q, args...).Scan(&p.Total); e != nil {
		return p, e
	}
	queryArgs := append(append([]any{}, args...), f.PageSize, (f.Page-1)*f.PageSize)
	rows, e := s.DB.QueryContext(ctx, "SELECT id,payload,received_ns FROM "+s.table+q+" ORDER BY generated_ns DESC LIMIT ? OFFSET ?", queryArgs...)
	if e != nil {
		return p, e
	}
	defer rows.Close()
	for rows.Next() {
		r, e := scanRecord(rows)
		if e != nil {
			return p, e
		}
		p.Items = append(p.Items, r)
	}
	return p, rows.Err()
}

// Daily values are the LAST snapshot for each phone-local day, never SUM of uploads.
func (s *MySQL) Days(ctx context.Context, f Filter) ([]Record, error) {
	q, args := filterSQL(f)
	query := fmt.Sprintf("SELECT s.id,s.payload,s.received_ns FROM %s s JOIN (SELECT MAX(generated_ns) AS ns FROM %s%s GROUP BY local_day) d ON s.generated_ns=d.ns ORDER BY s.local_day ASC LIMIT 366", s.table, s.table, q)
	rows, e := s.DB.QueryContext(ctx, query, args...)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	result := []Record{}
	for rows.Next() {
		r, e := scanRecord(rows)
		if e != nil {
			return nil, e
		}
		result = append(result, r)
	}
	return result, rows.Err()
}
