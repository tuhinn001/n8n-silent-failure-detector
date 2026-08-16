# T9 — Backup / Restore Drill Log

**Date:** 2026-08-15
**Target:** `ops` Postgres database — tables `wf_expectation`, `wf_run`, `wf_heartbeat`, `wf_alert`
**Method:** Executed live via a scratch n8n workflow (Manual Trigger + Postgres "Execute Query" node, same "Postgres account" credential used by Workflow A/B).

## Steps performed

1. **Backup** — ran a single query that exports all 4 tables as one JSON snapshot:
   ```sql
   SELECT
     (SELECT COALESCE(json_agg(t), '[]') FROM wf_expectation t) AS wf_expectation,
     (SELECT COALESCE(json_agg(t), '[]') FROM wf_run t) AS wf_run,
     (SELECT COALESCE(json_agg(t), '[]') FROM wf_heartbeat t) AS wf_heartbeat,
     (SELECT COALESCE(json_agg(t), '[]') FROM wf_alert t) AS wf_alert;
   ```
   Saved to `backup-drill-2026-08-15.json` (3 wf_run rows, 1 wf_expectation, 1 wf_heartbeat, 3 wf_alert rows).

2. **Simulated total data loss**:
   ```sql
   TRUNCATE TABLE wf_run, wf_heartbeat, wf_alert, wf_expectation;
   ```
   Verified all 4 tables at 0 rows via a `count(*)` query.

3. **Restore** — reinserted every row from the backup JSON using `json_populate_recordset`, in FK-safe order (`wf_expectation` first, then `wf_run` / `wf_heartbeat` / `wf_alert`).

4. **Verification** — re-ran the same export query used in step 1 and diffed it against the original backup. Result: exact match, including edge-case fields that are easy to get wrong in a naive restore (`finished_at: null` on the still-open `T4-stuck-crash-001` row, `attempt: 2` on the replayed `T5-replay-001` row).

## Result: PASS

The ops database can be fully recovered from a JSON snapshot with no data loss, including in-flight/edge-case rows. Recommended cadence for a real deployment: run the backup query on a daily schedule and store the output off-box (e.g. S3/Drive), since this is what actually gets restored if the ops Postgres instance is lost.
