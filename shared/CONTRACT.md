# Snapshot API v1

The exact JSON field names and nesting are illustrated in `snapshot.example.json`.
Every top-level section is REQUIRED; numeric/date/detail fields may be JSON null.
Native encoders may omit optional null-valued detail keys; consumers must accept omission as null.
`schemaVersion` is 1. `dataMode` is `healthkit` or `demo`.
`generatedAt` is the time the iPhone queried and assembled the snapshot (ISO 8601 UTC), NOT the sensor time.
`day` is the iPhone local calendar day YYYY-MM-DD; `timeZone` is an IANA zone.
`sourcePolicy` is `healthKit`: activity uses HealthKit statistics/system activity summary, not raw-source addition.
Each section status is `ok`, `empty`, or `error`; do not interpret empty/null as zero or as a known permission denial.
All numeric values must be finite and nonnegative. heartRate.bpm must be positive when provided.
Sleep uses an overnight window ending at local noon (most recent noon boundary appropriate to the current morning), excludes inBed, selects one preferred source (Apple Watch if available), and unions overlapping sleep intervals. This day bucket can include naps; label it sleep summary rather than a single continuous night. Do not add awake to totalMinutes. `sourceName` describes the selected sleep source.
Activity ring goal values are optional and read from HealthKit. `moveMode` is `energy`, `time`, or `unknown`; use moveMinutes/moveGoalMinutes for time mode.
heartRate.measuredAt is the sensor sample time; always render it alongside the latest bpm.
workout is the most recent completed workout within the last 30 days; fields may be absent for unknown distance/energy.
`warnings` contains user-facing, non-sensitive problem descriptions; never tokens or raw HTTP response bodies.

## Local single-user relay (app/server 0.3)

**No identity authentication. Trusted LAN only. Every client that can reach the server can read, upload and delete all history. Do not expose it publicly. HTTPS and CORS are not authentication.**

- `GET /healthz`: status and API version only.
- `PUT /v1/snapshot`: no token; full JSON snapshot, dataMode=healthkit only, limit 128 KiB.
- `GET /v1/snapshot`: no token; returns `{ "snapshot": <snapshot>, "receivedAt": <server timestamp> }`; 404 if none.
- `DELETE /v1/snapshot`: no token; deletes ALL MySQL snapshot history and latest pointer; idempotent 204.
- `/api/admin/*`: no token. `/api/admin/me` reports `authMode: none`, not an authenticated identity.
- Legacy Authorization headers are ignored. Old security YAML keys are accepted but not enforced; new configs generate no tokens.
- Browser origins are checked on requests; /v1 CORS allowlist remains configurable, admin is same-origin. Native clients without Origin are accepted. No cookies.
- Errors use `{ "detail": "human-readable message" }` without echoed health content.
- Older snapshots or conflicting equal timestamps return 409; identical retries do not duplicate records.
- Responses remain no-store; payload checks, null semantics and schema version are unchanged.

## UX

Native App reads locally without relay configuration. Upload remains opt-in and demo never uploads.
Phone and plugin require only the service base URL. URLs may not contain credentials or query strings.
Vue opens the dashboard directly and reloads without login. Local-use warnings are visible.
Old phone keychain relay credentials are removed within the app's own service/account scope; saved URL/cache are retained.
The plugin migrates old saved config to `{origin}` only and discards the old secret.
On failure keep prior data visibly marked cached with timestamps; never replace errors with demo data.
Deleting remote history requires confirmation in iPhone UI; the API itself is deliberately unauthenticated.

The historical Python implementation under server/ retains its old scoped-token contract; it is not the current default and cannot be used with 0.3 clients without authentication changes.

## Even history reader (plugin 0.5)

The latest snapshot contract above is unchanged. The plugin reads the Gin history endpoints independently:

- `GET /v1/history/status`: `{epoch, count, counts, earliest, latest}`. Counts are archived sample counts, not proof of complete synchronization. Empty stores have null earliest/latest.
- `GET /v1/history/records?kind=&from=&to=&sourceID=&limit=50&cursor=`: `{items:[{rowID,sample,receivedAt}],total,nextCursor,sources}`. An empty nextCursor means no older page. Cursors are opaque. Changing filters starts from the first page.
- `sources` lists `{sourceID,sourceName,count,earliest,latest}` for the entire type/date range, independent of the selected source and pagination. Source IDs are exact strings, including case and trailing spaces. The plugin does not use display names as identities.
- `from/to` are inclusive sample start dates in each sample's saved timeZone. They are not sleep-summary noon-to-noon buckets. Records are ordered by startedAt descending, then rowID descending.
- `sample.kind` is sleep, steps, distance, activeEnergy, exercise, heartRate, workout or activitySummary. These are raw records, not cross-source totals. Sleep categories 0/1/2/3/4/5 mean in-bed/unspecified/awake/core/deep/REM; other categories stay unknown. The plugin never derives nightly totals from a partial page.
- The fifth glasses page shows a single selected archived record. Sample times include the year and use the sample timeZone. receivedAt is labelled as receipt time, never measurement time.
- The reader uses no credentials and never sends writes. Old servers without history report an independent history error; servers without sources can still serve unfiltered history. Explicit source filters require the 0.5 response and exact matching returned records.

See `backend/internal/history/model.go` for the complete sample schema and `docs/HISTORY.md` for upload and archive semantics.
