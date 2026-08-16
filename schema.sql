-- Core 1 -- Silent Failure Detector -- ops database schema
-- Applied against the 'ops' database (separate from n8n's own db, see initdb/01-create-ops-db.sql)
-- All comments in English/ASCII on purpose (Windows PowerShell 5.1 cannot reliably pipe non-ASCII text).

-- Which workflows are expected to run, how often, and how urgently to alert
CREATE TABLE IF NOT EXISTS wf_expectation (
  workflow_id        TEXT PRIMARY KEY,
  workflow_name       TEXT NOT NULL,
  expected_every_min INT  NOT NULL,
  grace_min           INT  NOT NULL DEFAULT 5,
  severity            TEXT NOT NULL DEFAULT 'warn',
  enabled              BOOLEAN NOT NULL DEFAULT true
);

-- Lifecycle of every run: written at start, updated at end (this is how F5 -- worker
-- crash mid-run -- gets caught: the row exists with status='running' and never closes)
CREATE TABLE IF NOT EXISTS wf_run (
  run_id        TEXT PRIMARY KEY,
  workflow_id   TEXT NOT NULL REFERENCES wf_expectation(workflow_id),
  execution_id  TEXT,
  started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at   TIMESTAMPTZ,
  status         TEXT NOT NULL DEFAULT 'running',
  attempt        INT  NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_wf_run_workflow_started ON wf_run (workflow_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_wf_run_running ON wf_run (status) WHERE status = 'running';

-- Most recent successful completion per workflow (this is the "absence" signal)
CREATE TABLE IF NOT EXISTS wf_heartbeat (
  workflow_id      TEXT PRIMARY KEY REFERENCES wf_expectation(workflow_id),
  last_success_at TIMESTAMPTZ NOT NULL
);

-- Alert dedupe / cooldown so the same problem doesn't spam every 5 minutes
CREATE TABLE IF NOT EXISTS wf_alert (
  alert_key   TEXT PRIMARY KEY,
  first_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_sent   TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ
);

-- Register the two test workflows so the watchdog has something to check
INSERT INTO wf_expectation (workflow_id, workflow_name, expected_every_min, grace_min, severity)
VALUES
  ('YdTyR38i8SkpQABN', 'TEST-victim-webhook', 5, 2, 'warn')
ON CONFLICT (workflow_id) DO NOTHING;
