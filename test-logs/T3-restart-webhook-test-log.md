# T3 — n8n Restart / Webhook Registration Drill Log

**Date:** 2026-08-15
**Target:** Live n8n instance (Docker, localhost:5679), workflows `TEST-victim-webhook` and `watchdog`.

## What was tested

The spec's original F3 concern was "webhook registration doesn't survive an n8n restart" (URL starts 404ing).
That is **not** what happened here — but a more serious, silent variant of the same failure class was caught live during the test.

## Steps performed

1. Built `TEST-victim-webhook` (GET webhook, path `t3-victim-webhook`, respond immediately), published/activated it.
2. Baseline hit before restart: `GET /webhook/t3-victim-webhook` → `{"message":"Workflow was started"}`. Execution #90 of `watchdog` also completed successfully at 21:43:00.
3. Tuhin restarted the n8n Docker container.
4. Re-hit the same URL immediately after restart → **identical response**, `{"message":"Workflow was started"}`. On its face, the webhook "survived."
5. Checked the Executions list (both the individual workflow and the global Overview → Executions) to confirm the request actually *ran*, not just that it was acknowledged. Finding:
   - The post-restart webhook hit (exec #94) sat in **`Queued — Starting soon`** indefinitely, never transitioning to Running/Success.
   - The pre-restart-but-not-yet-processed hit (exec #93) was stuck the same way.
   - `watchdog`'s own Schedule Trigger (every 2 min) also stopped producing any Running/Success executions after #90 at 21:43:00 — every fire since has queued and never run.
   - Older stuck executions (#51–#54, #10) show this isn't unique to this incident — this n8n instance has a queue/worker-processing weakness that a restart can trigger, likely the Bull/Redis queue producer (main process) coming back before/without its worker reconnecting.

## Real finding

**The webhook HTTP endpoint itself survives a restart and returns a healthy-looking 200 response — but the actual workflow execution silently stops processing.** This is worse than a 404: the caller (or a naive monitor) sees success and has no idea nothing actually ran. Classic F3 (URL breaks outright) did **not** reproduce in this Docker setup; this queue-stall failure is the real, observed restart risk here.

## Proof the safety net catches it anyway

Because `watchdog`'s own Schedule Trigger got caught in the same stall, the watchdog went silent starting 21:43. This is exactly the scenario the T8 dead-man's switch exists for:

- healthchecks.io `core1-watchdog` check: `21:43 down → up` (last good ping) → `21:48 up → down` (period 3 min + grace 2 min = 5 min, matches exactly).
- Check has been in DOWN state continuously since, email notification channel is ON (`hassanrashadul50@gmail.com`) — the same alert path already proven to deliver in T8.

So even though this specific failure mode (queue stall post-restart) is *not* something the ops-DB sweep queries can see (the affected workflow never got the chance to write a `wf_run`/`wf_heartbeat` row in the first place), the **external, independent dead-man's switch caught the meta-failure** — the watchdog monitoring the workflows went down, and something outside n8n noticed. This is the concrete case for why Core 1 needs a layer that doesn't depend on n8n's own execution engine being healthy.

## Result: PASS (with a real finding, not a hypothetical)

Confirmed and documented, with live evidence:
1. A genuine, reproducible n8n/Docker restart failure mode exists in this environment (queue stall, not webhook 404).
2. It is silent from the caller's perspective (200 OK, nothing actually runs).
3. The independent dead-man's switch (T8) correctly detects and alerts on the resulting watchdog outage, which the in-DB sweep logic cannot.

## Root cause (confirmed)

`core1-queue-lab/docker-compose.yml` runs n8n in **queue mode** (`EXECUTIONS_MODE=queue`, Redis-backed) with execution split across `n8n-main` (UI + webhook intake) and `n8n-worker` (2 replicas, does the actual processing). The worker service is deliberately set to `restart: "no"` — intentional, left over from the earlier worker-kill test (T4/T5), so a killed worker wouldn't silently self-heal and mask that test's result.

`docker restart <container>` only restarts containers that already exist; it does not recreate ones that were previously stopped/removed. Since the worker containers were down from the earlier kill test, the restart brought back `n8n-main`, `postgres`, and `redis` — which is why the webhook kept accepting requests and queuing jobs — but never brought back the workers, so nothing ever dequeued and ran.

## Fix applied and verified

```
docker compose up -d
```
(run from `core1-queue-lab/`) recreated and started `n8n-worker-1` and `n8n-worker-2` (`docker compose ps` beforehand showed only 3 of 5 services running — main, postgres, redis; workers were missing entirely).

Immediately after, the backlog drained: executions #51–#54 (watchdog) and #93–#94 (webhook) all flipped from `Queued` to `Success`. healthchecks.io confirmed independently: `21:48 up→down` → `22:02 down→up`, watchdog pinging normally again on schedule.

## Operational takeaway

For a real (non-lab) deployment, the n8n worker service should use `restart: always` (or `unless-stopped`), not `restart: "no"` — the "no" setting is only appropriate for a deliberate chaos-testing lab like this one, where you want a killed worker to *stay* dead so the test result is unambiguous. Documented here so this doesn't get carried into a client/production compose file by accident.
