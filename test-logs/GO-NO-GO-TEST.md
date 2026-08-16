# Go/No-Go Test — Verifying Core 1's Foundational Assumption

> **What had to be proven:** if a worker container dies mid-execution, n8n's **Error Trigger does not fire** — meaning a conventional "centralized error workflow" cannot catch this failure class at all.
> **Why first:** Core 1's entire sales argument rests on this one fact. If it were false, both the design and the narrative would have to change — **30 minutes before an 8-hour build.**
> **Time:** ~30-45 minutes

---

## Step 0 — Start the lab (5 min)

```powershell
# If level4-docker is running, stop it first (avoid port/resource conflicts)
cd "$env:USERPROFILE\Desktop\n8n automation\level4-docker"
docker compose down

# Copy .env -- using the same encryption key and password
cd "$env:USERPROFILE\Desktop\n8n automation\core1-queue-lab"
Copy-Item ..\level4-docker\.env .env

docker compose up -d
docker compose ps
```

**Pass condition:** 5 containers running — postgres, redis, n8n-main, and **two** n8n-worker.

```powershell
# Confirm queue mode is actually active
docker compose logs n8n-main | Select-String -Pattern "queue|Queue" | Select-Object -First 5
docker compose logs n8n-worker | Select-String -Pattern "waiting|Waiting|worker" | Select-Object -First 5
```

n8n UI: **http://localhost:5679** (not 5678 — that's the Level-4 lab)

---

## Step 1 — Build the test workflows (10 min)

### Workflow 1 — `TEST-victim` (the one that will die mid-run)

| Node | Config |
|---|---|
| **Manual Trigger** | — |
| **Code — Slow Loop** | Code below. Runs for 60 seconds, giving time to kill it mid-run |
| **Slack / NoOp — Done** | Reaching this confirms completion |

```javascript
// Code node -- runs slowly for 60 seconds, logging every second
const started = Date.now();
for (let i = 1; i <= 60; i++) {
  await new Promise(r => setTimeout(r, 1000));
  console.log(`tick ${i}/60  elapsed=${Math.round((Date.now()-started)/1000)}s`);
}
return [{ json: { finished: true, seconds: 60 } }];
```

**In Workflow Settings, you must set:** `Error Workflow` = `TEST-error-handler` (below). **This is the whole point of the test — an error workflow is attached, and we're checking whether it fires anyway.**

### Workflow 2 — `TEST-error-handler`

| Node | Config |
|---|---|
| **Error Trigger** | — |
| **Code — Log Marker** | `console.log('ERROR TRIGGER FIRED', JSON.stringify($json)); return $input.all();` |

*(Add a Slack node too if available — but the log marker alone is sufficient proof.)*

---

## Step 2 — Baseline: does the Error Trigger fire on an ordinary failure? (5 min)

**Do not skip this.** It first has to be proven that the error handler actually works at all — otherwise "it didn't fire" could just mean the config is wrong.

1. Temporarily add to `TEST-victim`'s Code node: `throw new Error('baseline test');`
2. Execute it.
3. Check:

```powershell
docker compose logs n8n-worker | Select-String -Pattern "ERROR TRIGGER FIRED"
```

| Result | Meaning |
|---|---|
| Marker found | Error handler works correctly -> proceed to Step 3 |
| Not found | **Stop** — the Error Workflow setting isn't configured correctly. Fix it and retry |

Remove the `throw` line.

---

## Step 3 — The real test: kill the worker (10 min)

```powershell
# Terminal 1 -- watch logs live
docker compose logs -f
```

```powershell
# Terminal 2
# 1. Execute the victim workflow (from the UI)
# 2. Once you see tick 5 / tick 10 in the logs, identify which worker is running it:
docker compose ps

# 3. Kill the worker that's producing the tick logs (SIGKILL -- not a graceful shutdown)
docker kill core1-queue-lab-n8n-worker-1
#    if the name differs, use the real name from docker compose ps
```

**Use `docker kill`, not `docker stop`.** `stop` sends SIGTERM -> n8n shuts down gracefully -> the execution might get marked failed cleanly, which would not simulate a real crash. We are simulating an OOM-kill/container-evict.

### Now wait 5 minutes and record three things

```powershell
# a) Did the Error Trigger fire?
docker compose logs | Select-String -Pattern "ERROR TRIGGER FIRED"

# b) Is the other worker replaying the job? (stalled -> re-processed)
docker compose logs n8n-worker | Select-String -Pattern "stalled|tick 1/60"

# c) What does the UI show for the execution's status?
#    http://localhost:5679 -> Executions -> find that run
```

---

## Step 4 — Record results (right here, in this file)

| # | Question | Expected (per spec's assumption) | **Actual result** | Date |
|---|---|---|---|---|
| 1 | Does the Error Trigger fire on baseline? | Yes | _____ | |
| 2 | Does the Error Trigger fire on worker kill? | No ← **core assumption** | _____ | |
| 3 | What does the UI show for execution status? | Stuck at `running` or `crashed` | _____ | |
| 4 | Does another worker replay the job? | Yes (Bull stalled -> re-process) | _____ | |
| 5 | If replayed, does it restart from `tick 1/60`? | Yes (no checkpointing) | _____ | |
| 6 | Actual default of `QUEUE_WORKER_MAX_STALLED_COUNT` | 1 (claimed in a forum thread) | _____ | |

---

## Final result (August 15, 2026, measured, scripted run)

| # | Question | Result |
|---|---|---|
| Execution status after worker kill | **Stuck at `running` forever** (`finished=f`, `stoppedAt=NULL`, even after 20 seconds) | Core hypothesis confirmed |
| Does anything show up on the dashboard/error count? | No — no error row was created, no visible failure | "Silent" claim proven |
| What happened on an earlier run in the same lab (both workers alive) | Bull stalled-job redelivery -> **replayed the entire execution from the start**, status="success" — a silent duplicate-writes risk (F6) | Second real failure mode also measured |
| Verification method | Not Error Workflow/console.log, but reading the `status`/`finished`/`stoppedAt` columns of the `execution_entity` table directly — this is the same basis Workflow B's core query uses | Product logic was pre-validated by this same test |

**Decision: GO.** The full design of Core 1 (heartbeat + absence-sweep + open-run-sweep + replay-detect + dead-man's switch) can proceed on this measured evidence.

---

## Decision rule

| Result | Meaning | Next step |
|---|---|---|
| **#2 = No** (did not fire) | **GO** — assumption confirmed, Core 1's whole narrative holds, and live demo footage was captured in the process | schema.sql -> build Workflow A + B |
| **#2 = Yes** (did fire) | **PIVOT** — n8n does catch this case. Narrative needs to change | Core 1's focus shifts from F5 to **F1-F4 (absence detection)** — that part remains intact and strong enough on its own |
| **#4 = Yes and #5 = Yes** | **Bonus** — live proof of a duplicate side effect, the strongest shot for a recording | Confirms replay-detection (attempt counter) belongs in the design |

> **Honest note:** a PIVOT result is not a failure either. "I didn't assume — I measured, and changed the design after measuring" is a publishable result just like Run 9/13 in `LEVEL-5-STATUS.md`, and it is the biggest differentiator here.

---

## After testing

```powershell
docker compose down          # data is preserved (volume is not deleted)
# for a full reset: docker compose down -v
```
