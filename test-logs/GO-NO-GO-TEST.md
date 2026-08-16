# Go/No-Go টেস্ট — Core 1-এর ভিত্তি-অনুমান যাচাই

> **যা প্রমাণ করতে হবে:** worker container মাঝপথে মরে গেলে n8n-এর **Error Trigger ফায়ার করে না** — অর্থাৎ প্রচলিত "centralized error workflow" এই ব্যর্থতা-শ্রেণী ধরতেই পারে না।
> **কেন আগে:** Core 1-এর পুরো বিক্রয়-যুক্তি এই একটা তথ্যের উপর দাঁড়ানো। মিথ্যা হলে ডিজাইন ও narrative দুটোই বদলাতে হবে — **৮ ঘণ্টা বিল্ডের আগে ৩০ মিনিট।**
> **সময়:** ~৩০-৪৫ মিনিট

---

## ধাপ ০ — ল্যাব চালু (৫ মিনিট)

```powershell
# level4-docker চললে আগে থামান (পোর্ট/রিসোর্স সংঘর্ষ এড়াতে)
cd "$env:USERPROFILE\Desktop\n8n automation\level4-docker"
docker compose down

# .env কপি করুন — একই encryption key ও password ব্যবহার করছি
cd "$env:USERPROFILE\Desktop\n8n automation\core1-queue-lab"
Copy-Item ..\level4-docker\.env .env

docker compose up -d
docker compose ps
```

**পাস-শর্ত:** ৫টা container চলছে — postgres, redis, n8n-main, ও **দুটো** n8n-worker।

```powershell
# queue mode সত্যিই চালু কিনা নিশ্চিত করুন
docker compose logs n8n-main | Select-String -Pattern "queue|Queue" | Select-Object -First 5
docker compose logs n8n-worker | Select-String -Pattern "waiting|Waiting|worker" | Select-Object -First 5
```

n8n UI: **http://localhost:5679** (৫৬৭৮ না — ওটা Level-4 ল্যাবের)

---

## ধাপ ১ — টেস্ট workflow বানান (১০ মিনিট)

### Workflow 1 — `TEST-victim` (যেটা মাঝপথে মরবে)

| নোড | কনফিগ |
|---|---|
| **Manual Trigger** | — |
| **Code — Slow Loop** | নিচের কোড। ৬০ সেকেন্ড ধরে চলবে, যাতে মাঝপথে মারার সময় পান |
| **Slack / NoOp — Done** | শেষ পর্যন্ত পৌঁছালে বোঝা যাবে |

```javascript
// Code node — ৬০ সেকেন্ড ধরে ধীরে চলে, প্রতি সেকেন্ডে লগ করে
const started = Date.now();
for (let i = 1; i <= 60; i++) {
  await new Promise(r => setTimeout(r, 1000));
  console.log(`tick ${i}/60  elapsed=${Math.round((Date.now()-started)/1000)}s`);
}
return [{ json: { finished: true, seconds: 60 } }];
```

**⚙️ Workflow Settings-এ অবশ্যই সেট করুন:** `Error Workflow` = `TEST-error-handler` (নিচেরটা)। **এটাই টেস্টের মূল বিষয় — error workflow যুক্ত আছে, তবু ফায়ার করবে কিনা দেখছি।**

### Workflow 2 — `TEST-error-handler`

| নোড | কনফিগ |
|---|---|
| **Error Trigger** | — |
| **Code — Log Marker** | `console.log('🚨 ERROR TRIGGER FIRED', JSON.stringify($json)); return $input.all();` |

*(Slack থাকলে Slack নোডও দিন — কিন্তু log marker-ই যথেষ্ট প্রমাণ।)*

---

## ধাপ ২ — Baseline: সাধারণ ব্যর্থতায় Error Trigger ফায়ার করে তো? (৫ মিনিট)

**এটা বাদ দেবেন না।** আগে প্রমাণ করতে হবে error handler আদৌ কাজ করে — নইলে "ফায়ার করেনি" মানে হতে পারে কনফিগ ভুল।

1. `TEST-victim`-এর Code node-এ সাময়িকভাবে যোগ করুন: `throw new Error('baseline test');`
2. Execute করুন।
3. চেক করুন:

```powershell
docker compose logs n8n-worker | Select-String -Pattern "ERROR TRIGGER FIRED"
```

| ফলাফল | মানে |
|---|---|
| ✅ marker পাওয়া গেছে | error handler ঠিক আছে → ধাপ ৩-এ যান |
| ❌ পাওয়া যায়নি | **থামুন** — Error Workflow সেটিং ঠিক হয়নি। ঠিক করে আবার করুন |

`throw` লাইনটা মুছে ফেলুন।

---

## ধাপ ৩ — ⭐ আসল টেস্ট: worker kill (১০ মিনিট)

```powershell
# টার্মিনাল ১ — লগ লাইভ দেখুন
docker compose logs -f
```

```powershell
# টার্মিনাল ২
# ১. victim workflow execute করুন (UI থেকে)
# ২. লগে tick 5 / tick 10 দেখা গেলে, কোন worker চালাচ্ছে বের করুন:
docker compose ps

# ৩. যে worker-এ tick লগ আসছে সেটাকে মারুন (SIGKILL — graceful shutdown না)
docker kill core1-queue-lab-n8n-worker-1
#    নাম আলাদা হলে docker compose ps-এর আসল নাম ব্যবহার করুন
```

**⚠️ `docker kill` ব্যবহার করুন, `docker stop` না।** `stop` SIGTERM পাঠায় → n8n graceful shutdown করে → execution হয়তো ঠিকভাবে fail মার্ক হয়ে যাবে, আর সেটা আসল crash সিমুলেট করবে না। আমরা OOM-kill/container-evict সিমুলেট করছি।

### এখন ৫ মিনিট অপেক্ষা করে তিনটা জিনিস রেকর্ড করুন

```powershell
# ক) Error Trigger ফায়ার করেছে?
docker compose logs | Select-String -Pattern "ERROR TRIGGER FIRED"

# খ) অন্য worker কি job replay করছে? (stalled → re-process)
docker compose logs n8n-worker | Select-String -Pattern "stalled|tick 1/60"

# গ) UI-তে execution-এর status কী?
#    http://localhost:5679 → Executions → ওই রানটা দেখুন
```

---

## ধাপ ৪ — ফলাফল লিখুন (এখানেই, এই ফাইলে)

| # | প্রশ্ন | প্রত্যাশা (spec-এর অনুমান) | **আসল ফলাফল** | তারিখ |
|---|---|---|---|---|
| ১ | Baseline-এ Error Trigger ফায়ার করে? | ✅ হ্যাঁ | _____ | |
| ২ | worker kill-এ Error Trigger ফায়ার করে? | ❌ না ← **মূল অনুমান** | _____ | |
| ৩ | UI-তে execution status কী দেখায়? | `running` বা `crashed`-এ আটকে থাকে | _____ | |
| ৪ | অন্য worker job replay করে? | ✅ হ্যাঁ (Bull stalled → re-process) | _____ | |
| ৫ | replay হলে `tick 1/60` থেকে শুরু করে? | ✅ হ্যাঁ (checkpointing নেই) | _____ | |
| ৬ | `QUEUE_WORKER_MAX_STALLED_COUNT`-এর আসল default | ১ (থ্রেডে দাবি) | _____ | |

---

## ✅ চূড়ান্ত ফলাফল (১৫ আগস্ট ২০২৬, মাপা, স্ক্রিপ্টেড রান)

| # | প্রশ্ন | ফলাফল |
|---|---|---|
| worker kill-এর পর execution status | **`running`-এ চিরকাল আটকে** (`finished=f`, `stoppedAt=NULL`, ২০ সেকেন্ড পরেও) | ✅ মূল হাইপোথিসিস নিশ্চিত |
| dashboard/error-count-এ কিছু দেখা যায়? | না — কোনো error row তৈরি হয়নি, কোনো visible failure নেই | ✅ "silent" দাবি প্রমাণিত |
| একই ল্যাবে আগের রানে (দুটো worker জীবিত) কী হয়েছিল | Bull stalled-job redelivery → **সম্পূর্ণ পুনরাবৃত্তি শুরু থেকে**, status="success" — নীরব duplicate-ঝুঁকি (F6) | ✅ দ্বিতীয় real failure-mode-ও মাপা হলো |
| যাচাই-পদ্ধতি | Error Workflow/console.log না, সরাসরি `execution_entity` টেবিলের `status`/`finished`/`stoppedAt` কলাম — এটাই Workflow B-এর মূল কোয়েরির ভিত্তি | ✅ প্রোডাক্ট-লজিক এই টেস্টেই প্রি-ভ্যালিডেটেড |

**সিদ্ধান্ত: GO।** Core 1-এর সম্পূর্ণ ডিজাইন (heartbeat + absence-sweep + open-run-sweep + replay-detect + dead-man's switch) এই মাপা প্রমাণের উপর দাঁড়িয়ে এগোনো যাবে।

---

## সিদ্ধান্ত-নিয়ম

| ফলাফল | মানে | পরবর্তী পদক্ষেপ |
|---|---|---|
| **#২ = না** (ফায়ার করেনি) | ✅ **GO** — অনুমান সঠিক, Core 1-এর পুরো narrative দাঁড়িয়ে গেল, এবং হাতে লাইভ demo footage-ও এসে গেল | schema.sql → Workflow A + B বিল্ড |
| **#২ = হ্যাঁ** (ফায়ার করেছে) | ⚠️ **PIVOT** — n8n এই কেসটা ধরে ফেলে। narrative বদলাতে হবে | Core 1-এর ফোকাস F5 থেকে সরিয়ে **F1-F4 (absence detection)**-এ নেওয়া হবে — ওটা এখনো অক্ষত ও যথেষ্ট শক্তিশালী |
| **#৪ = হ্যাঁ এবং #৫ = হ্যাঁ** | ⭐ **বোনাস** — duplicate side-effect লাইভ প্রমাণ, রেকর্ডিংয়ের সবচেয়ে শক্তিশালী শট | replay-detection (attempt counter) ডিজাইনে রাখা নিশ্চিত |

> **সৎ নোট:** PIVOT ফলাফলও ব্যর্থতা না। "আমি ধরে নিইনি, মেপেছি — এবং মাপার পর ডিজাইন বদলেছি" — এটা `LEVEL-5-STATUS.md`-এর রান ৯/১৩-এর মতোই একটা প্রকাশযোগ্য ফলাফল, এবং এটাই আপনার সবচেয়ে বড় differentiator।

---

## টেস্ট শেষে

```powershell
docker compose down          # ডেটা থাকবে (volume মোছে না)
# পুরো রিসেট চাইলে: docker compose down -v
```
