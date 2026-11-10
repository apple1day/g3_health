package store

import (
	"context"
	"errors"
	"github.com/apple1day/g3_health/backend/internal/snapshot"
	"time"
)

var ErrNotFound = errors.New("snapshot not found")
var ErrConflict = errors.New("equal or newer snapshot exists")

type Record struct {
	ID         int64             `json:"id"`
	Snapshot   snapshot.Snapshot `json:"snapshot"`
	ReceivedAt time.Time         `json:"receivedAt"`
}
type Filter struct {
	From, To       string
	Page, PageSize int
}
type Page struct {
	Items    []Record `json:"items"`
	Total    int64    `json:"total"`
	Page     int      `json:"page"`
	PageSize int      `json:"pageSize"`
}
type Overview struct {
	Latest   *Record `json:"latest"`
	Count    int64   `json:"snapshotCount"`
	DayCount int64   `json:"dayCount"`
	FirstDay *string `json:"firstDay"`
	LastDay  *string `json:"lastDay"`
}
type Repository interface {
	Ping(context.Context) error
	Put(context.Context, snapshot.Snapshot) (time.Time, error)
	Latest(context.Context) (Record, error)
	DeleteAll(context.Context) error
	Overview(context.Context) (Overview, error)
	List(context.Context, Filter) (Page, error)
	Days(context.Context, Filter) ([]Record, error)
	Get(context.Context, int64) (Record, error)
}
