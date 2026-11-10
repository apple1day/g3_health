// Package snapshot implements the existing iPhone / Even Hub schema v1.
package snapshot

import (
 "bytes"
 "encoding/json"
 "errors"
 "io"
 "math"
 "strings"
 "time"
 _ "time/tzdata"
 "unicode/utf8"
)

var ErrInvalid = errors.New("invalid snapshot")

type Sleep struct {
 Status string `json:"status"`
 StartedAt *time.Time `json:"startedAt"`
 EndedAt *time.Time `json:"endedAt"`
 TotalMinutes *float64 `json:"totalMinutes"`
 CoreMinutes *float64 `json:"coreMinutes"`
 DeepMinutes *float64 `json:"deepMinutes"`
 REMMinutes *float64 `json:"remMinutes"`
 UnspecifiedMinutes *float64 `json:"unspecifiedMinutes"`
 AwakeMinutes *float64 `json:"awakeMinutes"`
 SourceName *string `json:"sourceName"`
}
type Activity struct {
 Status string `json:"status"`
 Steps *float64 `json:"steps"`
 DistanceMeters *float64 `json:"distanceMeters"`
 ActiveEnergyKcal *float64 `json:"activeEnergyKcal"`
 ExerciseMinutes *float64 `json:"exerciseMinutes"`
 StandHours *float64 `json:"standHours"`
 ActiveEnergyGoalKcal *float64 `json:"activeEnergyGoalKcal"`
 ExerciseGoalMinutes *float64 `json:"exerciseGoalMinutes"`
 StandGoalHours *float64 `json:"standGoalHours"`
 MoveMode string `json:"moveMode"`
 MoveMinutes *float64 `json:"moveMinutes"`
 MoveGoalMinutes *float64 `json:"moveGoalMinutes"`
}
type HeartRate struct {
 Status string `json:"status"`
 BPM *float64 `json:"bpm"`
 MeasuredAt *time.Time `json:"measuredAt"`
}
type Workout struct {
 Status string `json:"status"`
 Kind *string `json:"kind"`
 StartedAt *time.Time `json:"startedAt"`
 EndedAt *time.Time `json:"endedAt"`
 DurationSeconds *float64 `json:"durationSeconds"`
 DistanceMeters *float64 `json:"distanceMeters"`
 ActiveEnergyKcal *float64 `json:"activeEnergyKcal"`
}
type Snapshot struct {
 SchemaVersion int `json:"schemaVersion"`
 DataMode string `json:"dataMode"`
 GeneratedAt time.Time `json:"generatedAt"`
 TimeZone string `json:"timeZone"`
 Day string `json:"day"`
 SourcePolicy string `json:"sourcePolicy"`
 Sleep *Sleep `json:"sleep"`
 Activity *Activity `json:"activity"`
 HeartRate *HeartRate `json:"heartRate"`
 Workout *Workout `json:"workout"`
 Warnings []string `json:"warnings"`
}

// Parse accepts omitted optional detail keys, but never absent/null sections.
// All errors deliberately omit the submitted content (health data or credentials).
func Parse(raw []byte, now time.Time, secrets ...string) (Snapshot, error) {
 var s Snapshot
 if !utf8.Valid(raw) { return s, ErrInvalid }
 d := json.NewDecoder(bytes.NewReader(raw)); d.UseNumber()
 if err := uniqueJSON(d, 0); err != nil { return s, ErrInvalid }
 if _, err := d.Token(); err != io.EOF { return s, ErrInvalid }
 d = json.NewDecoder(bytes.NewReader(raw)); d.DisallowUnknownFields()
 if err := d.Decode(&s); err != nil { return s, ErrInvalid }
 if err := s.Validate(now); err != nil { return Snapshot{}, err }
 // Canonicalize before comparing retries; offsets / optional nulls are not changes.
 s.GeneratedAt = s.GeneratedAt.UTC()
 for _, v := range []**time.Time{&s.Sleep.StartedAt, &s.Sleep.EndedAt, &s.HeartRate.MeasuredAt, &s.Workout.StartedAt, &s.Workout.EndedAt} {
  if *v != nil { u := (*v).UTC(); *v = &u }
 }
 b, err := json.Marshal(s)
 if err != nil { return Snapshot{}, ErrInvalid }
 for _, secret := range secrets {
  if secret != "" && bytes.Contains(b, []byte(secret)) { return Snapshot{}, ErrInvalid }
 }
 return s, nil
}
func (s Snapshot) Validate(now time.Time) error {
 if s.SchemaVersion != 1 || s.DataMode != "healthkit" || s.SourcePolicy != "healthKit" || s.GeneratedAt.IsZero() || s.GeneratedAt.Year() < 2000 || s.GeneratedAt.Year() > 2200 || s.GeneratedAt.After(now.Add(5*time.Minute)) { return ErrInvalid }
 if len(s.TimeZone) == 0 || len(s.TimeZone) > 80 || s.TimeZone == "Local" || strings.Contains(s.TimeZone, "\\") { return ErrInvalid }
 zone, err := time.LoadLocation(s.TimeZone)
 if err != nil { return ErrInvalid }
 day, err := time.Parse("2006-01-02", s.Day)
 if err != nil || day.Format("2006-01-02") != s.Day || s.GeneratedAt.In(zone).Format("2006-01-02") != s.Day { return ErrInvalid }
 if s.Sleep == nil || s.Activity == nil || s.HeartRate == nil || s.Workout == nil || s.Warnings == nil || len(s.Warnings)>24 { return ErrInvalid }
 for _, status := range []string{s.Sleep.Status,s.Activity.Status,s.HeartRate.Status,s.Workout.Status} {
  if status != "ok" && status != "empty" && status != "error" { return ErrInvalid }
 }
 if s.Activity.MoveMode != "energy" && s.Activity.MoveMode != "time" && s.Activity.MoveMode != "unknown" { return ErrInvalid }
 numbers := []*float64{s.Sleep.TotalMinutes,s.Sleep.CoreMinutes,s.Sleep.DeepMinutes,s.Sleep.REMMinutes,s.Sleep.UnspecifiedMinutes,s.Sleep.AwakeMinutes,s.Activity.Steps,s.Activity.DistanceMeters,s.Activity.ActiveEnergyKcal,s.Activity.ExerciseMinutes,s.Activity.StandHours,s.Activity.ActiveEnergyGoalKcal,s.Activity.ExerciseGoalMinutes,s.Activity.StandGoalHours,s.Activity.MoveMinutes,s.Activity.MoveGoalMinutes,s.HeartRate.BPM,s.Workout.DurationSeconds,s.Workout.DistanceMeters,s.Workout.ActiveEnergyKcal}
 for _, v := range numbers { if v != nil && (math.IsNaN(*v) || math.IsInf(*v,0) || *v < 0) { return ErrInvalid } }
 if s.HeartRate.BPM != nil && (*s.HeartRate.BPM<=0 || s.HeartRate.MeasuredAt==nil) { return ErrInvalid }
 if !interval(s.Sleep.StartedAt,s.Sleep.EndedAt) || !interval(s.Workout.StartedAt,s.Workout.EndedAt) { return ErrInvalid }
 for _, str := range []*string{s.Sleep.SourceName,s.Workout.Kind} { if str!=nil && utf8.RuneCountInString(*str)>160 { return ErrInvalid } }
 for _, str := range s.Warnings { if utf8.RuneCountInString(str)>300 { return ErrInvalid } }
 return nil
}
func interval(a,b *time.Time) bool { return a==nil || b==nil || !b.Before(*a) }

// encoding/json otherwise silently accepts duplicate object keys. Bound depth too.
func uniqueJSON(d *json.Decoder, depth int) error {
 if depth>32 { return ErrInvalid }
 t,err:=d.Token(); if err!=nil { return err }
 delim,ok:=t.(json.Delim); if !ok { return nil }
 switch delim {
 case '{':
  keys:=map[string]bool{}
  for d.More() { k,e:=d.Token(); if e!=nil { return e }; key,ok:=k.(string); if !ok||keys[key] {return ErrInvalid}; keys[key]=true; if e=uniqueJSON(d,depth+1);e!=nil{return e} }
  t,err=d.Token(); if err!=nil||t!=json.Delim('}') {return ErrInvalid}
 case '[':
  for d.More(){if err=uniqueJSON(d,depth+1);err!=nil{return err}}
  t,err=d.Token(); if err!=nil||t!=json.Delim(']'){return ErrInvalid}
 default: return ErrInvalid
 }
 return nil
}
