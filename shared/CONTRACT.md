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

## Single-user relay

- `GET /healthz`: unauthenticated, reports status and API version only.
- `PUT /v1/snapshot`: Authorization Bearer UPLOAD_TOKEN; JSON body is one full snapshot. Only accepts dataMode=healthkit. Size limit 128 KiB. Token cannot read.
- `GET /v1/snapshot`: Authorization Bearer READ_TOKEN; returns `{ "snapshot": <snapshot>, "receivedAt": <server ISO8601 timestamp> }`. 404 if none. Token cannot upload/delete.
- `DELETE /v1/snapshot`: Authorization Bearer UPLOAD_TOKEN; removes the stored snapshot; idempotent 204.
- CORS allowlist configurable; include plugin origin or `*` explicitly for dev. Bearer tokens required regardless of CORS. No cookies.
- Non-secret error shape: `{ "detail": "human-readable message" }`.
- Production requires HTTPS via reverse proxy. HTTP is strictly local LAN development.
- Private single-user instance: tokens generated locally, never in source, examples, static bundles, logs, or URLs.
- Reject stale uploads (generatedAt earlier than stored); return 409. Reject malformed, oversized and demo snapshots.

## UX

Native App reads locally even when relay is not configured. Upload is opt-in and never uploads demo.
Plugin defaults to unconnected state and offers explicit demo mode; demo never implies bridge connection or real data.
Plugin configuration uses base URL + read token. Native uses base URL + upload token. No API URLs/tokens in query strings.
On error keep prior snapshot visibly marked as cached with timestamps. On leaving demo, clear demo and restore real/empty state.
