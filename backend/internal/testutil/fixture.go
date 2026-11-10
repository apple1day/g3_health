// Package testutil contains synthetic test values, never personal health data.
package testutil
import("fmt";"time")
func Raw(t time.Time)[]byte{return []byte(fmt.Sprintf(`{"schemaVersion":1,"dataMode":"healthkit","generatedAt":%q,"timeZone":"UTC","day":%q,"sourcePolicy":"healthKit","sleep":{"status":"ok","totalMinutes":420,"coreMinutes":250,"deepMinutes":70,"remMinutes":100},"activity":{"status":"ok","steps":1200,"distanceMeters":800,"activeEnergyKcal":90,"moveMode":"energy"},"heartRate":{"status":"ok","bpm":70,"measuredAt":%q},"workout":{"status":"empty"},"warnings":[]}`,t.UTC().Format(time.RFC3339Nano),t.UTC().Format("2006-01-02"),t.Add(-time.Hour).UTC().Format(time.RFC3339Nano)))}
