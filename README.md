# Silent Failure Detector for n8n — catching the runs that never happened

**The failure that no monitoring tool reports: the workflow that didn't run at all.**

Every error-handling setup catches runs that *failed*. None of them catch runs that never *started* — a schedule that quietly stopped, a workflow someone left deactivated, a webhook registration lost on restart, a queue worker that died. These produce **no execution, therefore no error row, therefore nothing on any dashboard**. The dashboard shows zero failures, and zero failures looks exactly the same whether you had a clean day or your automation has been dead for six hours.

This repo is a working implementation that closes that gap: a heartbeat layer, an independent watchdog that alarms on the **absence** of a row rather than its contents, and a dead-man's switch outside n8n entirely — because a watchdog that dies with the system it watches is just one more silent failure.

> **Honest labelling:** this is a self-built lab project, not a paid client delivery. Every number below was measured on a live instance and the raw test logs are included in [`test-logs/`](test-logs/) — including the tests that found real bugs in my own build.

---

## The problem, stated precisely

| # | Failure | Why existing monitoring misses it |
|---|---|---|
| **F1** | Scheduled trigger silently stopped firing | No execution is created → no error row exists |
| **F2** | Workflow left deactivated by someone | Same — this is an absence, not a failure |
| **F3** | Webhook registration lost after a restart | Same |
| **F4** | Queue-mode worker died, nothing consuming the queue | Same |
| **F5** | Worker crashed mid-run (OOM kill / container evict) | Execution never reaches a terminal state → **the Error Trigger never fires** |
| **F6** | Bull marks the job stalled and another worker replays it | Silent replay → duplicate side effects, with no visible failure at all |

F5 is the one most people get wrong, so it was tested first, before any of this was built.

### Go/No-Go: the assumption was verified before the build, not after

The entire design rests on one claim — *"when a worker is SIGKILLed mid-run, n8n's Error Trigger does not fire."* If that were false, the design and the pitch would both have been wrong. So it was tested first, in ~45 minutes, before ~8 hours of building. Full log: [`test-logs/GO-NO-GO-TEST.md`](test-logs/GO-NO-GO-TEST.md).

**Measured result:** after `docker kill` of the worker running the job, the execution sat at `status = running`, `finished = false`, `stoppedAt = NULL` — **indefinitely**. No error row, no visible failure, nothing on the dashboard. Verified by reading n8n's own `execution_entity` table directly rather than trusting the UI.

A second, unplanned finding came out of the same lab: on an earlier run with both workers alive, Bull's stalled-job redelivery **replayed the entire execution from the start** and marked it `success`. That is F6 — a silent duplicate, reported as a clean run.

---

## Architecture

```
┌─ A. Heartbeat emitter (sub-workflow, called by every monitored workflow) ──┐
│   on start : INSERT wf_run (status='running')      ← this is how F5 is caught │
│   on finish: UPDATE wf_run status='success'                                   │
│              UPSERT wf_heartbeat.last_success_at = now()                      │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
┌─ B. Watchdog (separate workflow, own schedule) ───────────────────────────┐
│   B1 Absence sweep   : expectation JOIN heartbeat, now() - last_success_at  │
│                        > expected_every_min + grace   → F1, F2, F3, F4      │
│   B2 Open-run sweep  : wf_run status='running' older than threshold → F5    │
│   B3 Replay detect   : same run_id with attempt > 1                 → F6    │
│   B4 Alert cooldown + resolve/recovery notice (wf_alert table)             │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
┌─ C. Dead-man's switch (OUTSIDE n8n) ⭐ ───────────────────────────────────┐
│   The watchdog pings an external cron-monitor on every successful sweep.    │
│   If the ping stops, that external service alerts.                          │
│   Without this, the monitor is just one more thing that can die silently.   │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
┌─ D. Alert sink — Slack, severity-routed, with what/how long/last-success ─┐
└───────────────────────────────────────────────────────────────────────────┘
```

**Component C is the part most implementations skip.** A+B alone moves the problem one level up rather than solving it — you now have an unmonitored monitor.

### The design decision worth explaining

`run_id` is **never** derived from the n8n execution ID. A recovery run is a new execution with a new ID, so an execution-derived key cannot recognise the work it is retrying — the dedupe logic stays in place and quietly stops working. The key comes from the **business payload** (e.g. `order_id + date`), which stays constant across every retry of the same logical unit of work.

---

## Data model

Four tables in a separate `ops` database — deliberately *not* inside n8n's own schema, because n8n runs its own migrations and a shared schema is a restore/upgrade hazard. Full DDL: [`schema.sql`](schema.sql).

| Table | Purpose |
|---|---|
| `wf_expectation` | Registry: which workflows should run, how often, how urgently to alert |
| `wf_run` | Lifecycle row written at start, closed at finish — an open row is how a crash becomes visible |
| `wf_heartbeat` | Last successful completion per workflow — the absence signal |
| `wf_alert` | Dedupe/cooldown + `resolved_at` for recovery notices |

---

## What was tested, and what it found

The rule for this build was **skip nothing** — every failure class in the spec was executed live against the real system, not reasoned about. Three tests are documented in full in [`test-logs/`](test-logs/); the rest were run against the same live instance.

| Test | What it proves | Outcome |
|---|---|---|
| T1 | Happy path — heartbeat written on success | PASS |
| T2 | Absent heartbeat detected and alerted | PASS |
| T3 | Restart behaviour ([full log](test-logs/T3-restart-webhook-test-log.md)) | PASS — **found a real bug** |
| T4/T5 | Worker crash mid-run + silent replay detection | PASS |
| T6 | Alert cooldown — no spam every sweep | PASS |
| T7 | Resolve/recovery notice ([full log](test-logs/T7-resolve-notice-test-log.md)) | PASS — **found two real bugs** |
| T8 | Dead-man's switch fires when the watchdog itself dies | PASS |
| T9 | Backup → destroy → restore drill ([full log](test-logs/T9-backup-restore-drill-log.md)) | PASS |

### Three real bugs, caught live and fixed — not glossed over

**1. A restart leaves the webhook returning `200 OK` while nothing actually runs.**
The expected F3 failure was "the webhook URL starts 404ing." That is *not* what happened. After a restart the URL kept returning `{"message":"Workflow was started"}` — a completely healthy-looking response — while the execution sat in `Queued — Starting soon` forever and never ran. **This is worse than a 404**, because the caller and any naive monitor both see success. The in-database sweeps could not see it either (the affected workflow never got to write a row). What caught it was the external dead-man's switch: the watchdog's own schedule was caught in the same stall, its pings stopped, and the external monitor flagged it — `21:43 down → 21:48 up`, matching the configured period + grace exactly. This is the concrete argument for component C.

**2. Editing a live monitoring workflow silently disables it.**
In this n8n version, `Ctrl+S` alone does not republish — the Schedule Trigger stops firing until "Publish" is explicitly clicked again. Discovered because the watchdog went quiet ~18 minutes after an edit was saved. A real operational trap: the act of maintaining your monitor can turn it off.

**3. A Slack field silently sent the template instead of the value.**
After the Slack node's Operation dropdown was reselected (which wipes the fields), the Message Text was retyped in "Fixed" mode rather than "Expression" mode. The alert still delivered successfully — `"ok": true` — but the body contained the literal string `{{$json.alert_key.split('::')[1]}}`. Caught by inspecting the actual Slack API response of a live execution, not by looking at the workflow. An alert that delivers but is unreadable is functionally a silent failure.

Verified recovery path, from log T7 execution **#117**: real DB write confirmed via `RETURNING` (`resolved_at: 2026-08-15T16:46:02.102Z`), and the real Slack API response containing a correctly interpolated `✅ Resolved — absent_heartbeat — workflow ...`.

### Restore drill (T9)

Full export of all four tables → `TRUNCATE` all four → restore from the JSON snapshot via `json_populate_recordset` in FK-safe order → re-export and diff. **Exact match**, including the edge cases a naive restore gets wrong: `finished_at: null` on a still-open crashed run, and `attempt: 2` on a replayed run.

---

## Honest limitations

- **Detection latency is bounded by the sweep interval.** A one-minute sweep and a fifteen-minute sweep are different products; pick from the client's actual tolerance, not from a default.
- **`wf_expectation` must be maintained.** An unregistered workflow is invisible to this system. That is a deliberate trade-off (explicit registry over guessing), but it is a real operational cost.
- **The ops Postgres is a single point of failure.** If it dies, the sweeps die. The dead-man's switch covers the meta-failure, but it will only tell you *that* something is wrong, not what.
- **This does not replace APM/tracing.** It watches for the absence of automation-layer activity, not infrastructure metrics.
- **Multi-platform note:** the same absence-detection idea is only partially reproducible on Zapier/Make. On a Zapier Pro trial (verified August 2026) the minimum schedule interval available was **1 hour** — the whole event list was Custom Frequency (days/weeks/months), Every Day, Every Hour, Every Month, Every Week, with no minute-level option. On Make's Free plan the quota is **1,000 credits/month** (verified), against roughly 5,760 credits/month for a 15-minute two-module watchdog — about 6× over. Absence detection there is technically possible and economically impractical on those tiers. Anything beyond this is documented capability, not something I have built on those platforms.

---

## Repo contents

```
workflows/workflow-A-lib-heartbeat.json   # the heartbeat sub-workflow
workflows/workflow-B-watchdog.json        # the watchdog (sweeps, cooldown, resolve notice)
schema.sql                                # the four ops tables
docker-compose.yml                        # n8n queue mode lab (main + Redis + 2 workers)
test-logs/                                # raw test logs, including the failures
```

Import the two workflow JSONs into n8n, apply `schema.sql` to a Postgres database, register your workflows in `wf_expectation`, and point the watchdog's ping at any cron-monitoring service.

`docker-compose.yml` sets `restart: "no"` on the worker service **on purpose** — this is a chaos-testing lab where a killed worker must stay dead so the test result is unambiguous. For a real deployment, use `restart: always`.

---

## Why this exists

Most automation portfolios demonstrate that someone can connect nodes. This one exists to demonstrate the opposite skill: knowing what your automation *cannot tell you*, and building the layer that closes that gap — including testing an assumption before building on it, and publishing the bugs found in my own work rather than the version where everything worked the first time.
