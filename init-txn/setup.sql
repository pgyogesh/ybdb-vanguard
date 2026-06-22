-- ─────────────────────────────────────────────────────────────────────────────
-- setup.sql  —  Transactions & Isolation Levels exercise bootstrap
--
-- Run automatically by the devcontainer postStartCommand so the database is
-- READY THE MOMENT the cluster comes up:
--   • a "bank" table (accounts) for the lost-update / locking scenarios
--   • an "on-call roster" table (oncall) for the write-skew scenario
--   • both seeded with a known baseline so every scenario starts clean
--
-- Re-runnable: drops and recreates the demo tables, so it is safe to run again.
--
-- The devcontainer starts the tserver with yb_enable_read_committed_isolation=true
-- so the READ COMMITTED isolation level behaves like true PostgreSQL READ
-- COMMITTED (per-statement snapshots + automatic statement retries) instead of
-- silently mapping to SNAPSHOT. The other two YSQL isolation levels —
-- REPEATABLE READ (a.k.a. SNAPSHOT) and SERIALIZABLE — are always available.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Bank accounts: the lost-update & SELECT FOR UPDATE scenarios ──────────────
DROP TABLE IF EXISTS accounts;

CREATE TABLE accounts (
    id      INT  PRIMARY KEY,
    owner   TEXT NOT NULL,
    balance NUMERIC NOT NULL CHECK (balance >= 0));   -- no overdraft allowed

INSERT INTO accounts (id, owner, balance) VALUES
    (1, 'Alice', 1000);

-- ── On-call roster: the write-skew (SNAPSHOT vs SERIALIZABLE) scenario ────────
-- Business rule: AT LEAST ONE doctor must always remain on call.
DROP TABLE IF EXISTS oncall;

CREATE TABLE oncall (
    doctor    TEXT PRIMARY KEY,
    is_oncall BOOL NOT NULL);

INSERT INTO oncall (doctor, is_oncall) VALUES
    ('Alice', true),
    ('Bob',   true);

ANALYZE accounts;
ANALYZE oncall;

\echo '✅ Transactions exercise ready: accounts (Alice=1000) and oncall (Alice,Bob both on call) loaded.'
