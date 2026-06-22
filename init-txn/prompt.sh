#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Transactions & Isolation Levels demo  —  "The Double-Spend Problem"
#
# Distributed transactions in YugabyteDB are fully ACID across nodes. This demo
# shows the three YSQL isolation levels and the anomalies each one allows or
# prevents, using two concurrent sessions coordinated for a deterministic result.
#
#   Part 1 · Lost update      — READ COMMITTED, no locking → money disappears
#   Part 2 · The fix          — SELECT ... FOR UPDATE serializes the readers
#   Part 3 · Write skew       — REPEATABLE READ lets a hidden conflict through
#   Part 4 · Serializable     — the engine catches it (SQLSTATE 40001)
#   Part 5 · Retry loop       — the application pattern every app needs
#
# Pre-requisites (handled by the devcontainer postStartCommand → setup.sql):
#   - 1-node YugabyteDB cluster on 127.0.0.1:5433
#   - tserver flag yb_enable_read_committed_isolation=true (real READ COMMITTED)
#   - accounts (Alice = 1000) and oncall (Alice, Bob both on call) seeded
#
# The concurrent two-session scenarios live in concurrency.sh; this script
# narrates and runs them in order.
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * / count(*) glob-expanding

TYPE_SPEED=90
NO_WAIT=false
# Each `pe` normally pauses TWICE (before typing the command, and again before
# running it). This removes the first pause so the command types out as soon as
# you reach it; you then press Enter ONCE to run it. One pause per step.
NO_WAIT_DISPLAY_CMD=true
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Intro ──────────────────────────────────────────────────────────────────
p "=== YugabyteDB Transactions & Isolation Levels: The Double-Spend Problem ==="
p ""
p "YugabyteDB gives you fully distributed, ACID transactions with three YSQL isolation levels:"
p ""
p "  READ COMMITTED   each statement sees the latest committed data"
p "  REPEATABLE READ  the whole txn sees one consistent snapshot   (a.k.a. SNAPSHOT)"
p "  SERIALIZABLE     transactions behave as if run one after another"
p ""
p "The level you pick decides which concurrency anomalies are possible. Let's see them."
p ""
p "Our starting data — one account, and an on-call roster of two doctors:"

pe "ysqlsh -h 127.0.0.1 -X -c \"SELECT * FROM accounts; SELECT * FROM oncall;\""

# ── Part 1: Lost update ──────────────────────────────────────────────────────
p ""
p "=== Part 1: Lost update (READ COMMITTED, no locking) ==="
p ""
p "Classic app pattern: read the balance, compute the new value in the app, write it back."
p "Two transfers run at once — A withdraws 600, B withdraws 200 — each reading the balance first."
p "Correct final balance must be 1000 - 600 - 200 = 200. Watch what actually happens:"

pe "bash concurrency.sh lost-update"

p ""
p "Both transactions read 1000, so the later write clobbered the earlier one — a LOST UPDATE."
p "The single-statement form 'UPDATE ... SET balance = balance - 600' is safe (atomic), but the"
p "read-then-write-in-the-app pattern is not, unless you lock the row."

# ── Part 2: The fix — SELECT ... FOR UPDATE ──────────────────────────────────
p ""
p "=== Part 2: The fix — SELECT ... FOR UPDATE (pessimistic locking) ==="
p ""
p "Add FOR UPDATE to the read. Now B's read must WAIT for A's transaction to finish,"
p "so B reads the up-to-date balance (400) and both withdrawals apply correctly:"

pe "bash concurrency.sh for-update"

p ""
p "Final balance 200 — correct. FOR UPDATE makes the two readers take turns on the row."

# ── Part 3: Write skew ───────────────────────────────────────────────────────
p ""
p "=== Part 3: Write skew (REPEATABLE READ / SNAPSHOT) ==="
p ""
p "Locking one row isn't always enough. Business rule: at least one doctor must stay on call."
p "Both doctors are on call. Each runs: 'if 2+ are on call, I may go off.' They touch DIFFERENT"
p "rows, so there is no single row to lock — and snapshot isolation never sees the conflict:"

pe "bash concurrency.sh write-skew"

p ""
p "Both committed, and now NOBODY is on call. The reads and writes don't overlap on any row,"
p "so REPEATABLE READ (snapshot) allows it. This anomaly is called WRITE SKEW."

# ── Part 4: Serializable ─────────────────────────────────────────────────────
p ""
p "=== Part 4: Serializable prevents it (SQLSTATE 40001) ==="
p ""
p "Run the exact same scenario at SERIALIZABLE. YugabyteDB tracks the read/write dependency"
p "between the two transactions and refuses to let both commit:"

pe "bash concurrency.sh serializable"

p ""
p "One transaction is rolled back with a serialization-class failure — SQLSTATE 40001 (could not"
p "serialize) or, because YugabyteDB resolves conflicts with wait queues, 40P01 (deadlock)."
p "Either way the invariant holds: one doctor stays on call. SERIALIZABLE trades occasional"
p "retries for a guarantee that no anomaly can ever slip through."

# ── Part 5: Retry loop ───────────────────────────────────────────────────────
p ""
p "=== Part 5: The retry loop every app needs ==="
p ""
p "A 40001 / 40P01 is not fatal — it means 'try again'. Here two operations lock the same two"
p "rows in OPPOSITE order and deadlock; YugabyteDB aborts one, and the application's retry loop"
p "re-runs it and succeeds once the other operation has released its locks:"

pe "bash concurrency.sh retry"

p ""
p "Retrying on 40001/40P01 is not optional — it is how you write correct apps against a"
p "distributed database."

# ── Part 6: YugabyteDB-specific — distributed concurrency control ─────────────
p ""
p "=== Part 6: YugabyteDB-specific — distributed concurrency control ==="
p ""
p "Everything so far is standard SQL isolation. Here is what makes it DISTRIBUTED in YugabyteDB."
p ""
p "(1) Conflict handling + transaction priorities."
p "PostgreSQL only ever waits, then deadlocks. YugabyteDB has two conflict-resolution modes:"
p "  - Wait-on-Conflict (the default here): transactions queue and wait — which is exactly why"
p "    our SERIALIZABLE conflict in Part 4 surfaced as 'deadlock detected', not 'could not serialize'."
p "  - Fail-on-Conflict: the lower-PRIORITY transaction is aborted at once so the higher one wins."
p ""
p "Every YugabyteDB transaction carries a priority you can bias per session — make a critical job"
p "high-priority so it wins. Set a high priority and read it back with yb_get_current_transaction_priority():"

pe "ysqlsh -h 127.0.0.1 -X -c \"SET yb_transaction_priority_lower_bound = 0.9; BEGIN; SELECT doctor FROM oncall WHERE doctor = 'Alice' FOR UPDATE; SELECT yb_get_current_transaction_priority(); COMMIT;\""

p ""
p "(The NOTICE confirms this cluster uses Wait-on-Conflict, so the priority is a tie-breaker here;"
p "under Fail-on-Conflict it decides who wins outright. Either way every txn gets a priority.)"
p ""
p "(2) Distributed locks. PostgreSQL locks live in one server's memory (pg_locks). In YugabyteDB"
p "a lock lives in the TABLET that owns the row, as an intent record tagged with the distributed"
p "transaction id. yb_lock_status() shows them while a transaction holds a row:"

pe "bash concurrency.sh yb-locks"

p ""
p "So a 'lock' in YugabyteDB is a replicated, per-tablet intent record keyed by a distributed"
p "transaction id — not a latch in a single process. That is how locking scales across nodes."

# ── Summary ──────────────────────────────────────────────────────────────────
p ""
p "=== Key Mental Models  (Transactions & Isolation) ==="
p ""
p "READ COMMITTED   latest committed per statement; lost update possible → lock with FOR UPDATE"
p "REPEATABLE READ  one snapshot for the txn; no dirty/non-repeatable reads, but WRITE SKEW possible"
p "SERIALIZABLE     no anomalies at all; the engine raises 40001 instead → your app must RETRY"
p ""
p "LOCKING          SELECT ... FOR UPDATE / FOR SHARE / FOR NO KEY UPDATE / FOR KEY SHARE"
p "ERRORS           40001 = serialization failure (retry it)   40P01 = deadlock detected"
p "SET LEVEL        BEGIN ISOLATION LEVEL <level>   |   SET default_transaction_isolation = '<level>'"
p ""
p "YUGABYTE-SPECIFIC"
p "CONFLICT MODE    Wait-on-Conflict (queue + wait) vs Fail-on-Conflict (higher priority wins)"
p "PRIORITY         yb_transaction_priority_lower_bound / _upper_bound  +  yb_get_current_transaction_priority()"
p "DIST. LOCKS      yb_lock_status(null,null) — per-tablet intent records keyed by distributed txn id"
p ""
p "Rule of thumb: default to READ COMMITTED + FOR UPDATE for hot rows; use SERIALIZABLE when an"
p "invariant spans multiple rows (write skew). Always wrap transactions in a retry loop. On"
p "YugabyteDB, raise a critical job's transaction priority so it wins conflicts."
p ""

cmd

p ""
