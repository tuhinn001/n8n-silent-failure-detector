# T7 — Resolve / Recovery Notice (B10) Build + Test Log

**Date:** 2026-08-15
**Target:** Live n8n instance (Docker, localhost:5679), workflow `watchdog` (ID `4Ajb3DK1giPgObao`).

## What this adds

Originally out of MVP scope. Per the "skip nothing, this is credential proof" instruction, built and tested for real: when a condition that previously fired an alert (absent heartbeat, stuck open run, silent replay) stops reproducing, watchdog now posts a Slack "✅ Resolved" message and marks the alert closed in `wf_alert`, instead of just going silent.

## Design

- `wf_alert.resolved_at` (already existed, unused until now) is the source of truth for "open" vs "resolved."
- Each sweep now also runs `Sweep - Open Alerts` (`SELECT ... FROM wf_alert WHERE resolved_at IS NULL`) in parallel with the three finding sweeps.
- `Code - Build Alert Key` tags live findings with `source: 'current_finding'`; the open-alerts sweep is tagged `source: 'open_alert'`.
- `Merge - Current vs Open` (append) + `Code - Detect Resolved` compute the set difference: any `open_alert` whose `alert_key` is **not** in this sweep's `current_finding` set has cleared.
- `Mark Resolved` (Postgres) sets `resolved_at = now()` for those keys; `Filter - Only Real Resolutions` drops the node's placeholder-item output for 0-row updates (same quirk as the T6 cooldown guard).
- `Slack - Send Resolved` posts the recovery message.
- `Guard - Alert Cooldown`'s `ON CONFLICT` clause now also resets `resolved_at = NULL` on a fresh re-alert, so a recurring problem doesn't stay stuck "resolved."

New/changed nodes are in `workflow-B-watchdog.json` (canonical source, matches the live published version).

## Bugs found and fixed during build/test (not hypothetical — caught live)

1. **Workflow silently unpublished after edit.** In this n8n version, Ctrl+S alone does not republish a workflow — its Schedule Trigger stops firing until "Publish" is explicitly clicked again. Discovered because watchdog's Schedule Trigger stopped firing ~18 min after the T7 edits were saved. Fixed by publishing with version note "T7: add resolve/recovery notice ...". Confirms this is a real operational trap: editing a live monitoring workflow can quietly disable it.
2. **Slack message text sent as literal `{{ }}` instead of being interpolated.** After the Slack node's Operation dropdown had to be reselected (which wiped the pasted-in Channel/Message fields), the Message Text field was retyped into "Fixed" mode instead of "Expression" mode. Caught by inspecting the actual Slack API response JSON for a live execution (`"text"` field contained the literal string `{{$json.alert_key.split('::')[1]}}`). Fixed by switching the field to Expression mode; republished with a descriptive version note.

## End-to-end test performed

1. Manually reopened a resolved alert via SQL (`UPDATE wf_alert SET resolved_at = NULL, last_sent = now() - interval '31 minutes' WHERE alert_key = 'YdTyR3Bi8SkpQABN::absent_heartbeat'`) to set up a clean resolve cycle without re-triggering the 30-min cooldown.
2. Heartbeat was healthy at this point (already fixed from the earlier T2 test), so the next sweep correctly found `absent_heartbeat` was no longer a current finding.
3. Execution **#117** (Aug 15, 22:46:01 local / 16:46:01 UTC) confirmed the full chain:
   - `Code - Detect Resolved` input: `{"alert_key": "YdTyR3Bi8SkpQABN::absent_heartbeat", "first_seen": "2026-08-15T15:43:02.022Z", "last_sent": "2026-08-15T16:14:51.027Z", "source": "open_alert"}`
   - `Mark Resolved` output: `resolved_at: "2026-08-15T16:46:02.102Z"` (real DB write, confirmed via RETURNING clause).
   - `Filter - Only Real Resolutions`: 1 item passed through (correctly, since this was a genuine resolution not a 0-row placeholder).
   - `Slack - Send Resolved` actual API response: `"ok": true`, `"text": "✅ Resolved — absent_heartbeat — workflow `YdTyR3Bi8SkpQABN` (was alerting since 2026-08-15T15:43:02.022Z)\n..."` — correctly interpolated, not literal `{{ }}`.

## Result: PASS

Resolve/recovery notice (B10) is built, live-published, and verified end-to-end with real DB writes and a real delivered Slack message — including two real bugs (unpublish-on-edit, unevaluated expression field) found and fixed during testing rather than glossed over.
