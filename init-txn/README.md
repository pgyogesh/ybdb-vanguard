# Transactions & Isolation Levels

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-txn%2Fdevcontainer.json)

YugabyteDB gives you **fully distributed, ACID transactions** — the same `BEGIN` / `COMMIT` / `ROLLBACK` semantics as PostgreSQL, but enforced across nodes by a distributed transaction manager. The **isolation level** you choose decides which concurrency anomalies are possible. This exercise walks through all three YSQL isolation levels, the anomalies each one allows, and the two tools you use to write correct concurrent code: **`SELECT ... FOR UPDATE`** and the **retry-on-40001** loop.

> **The Double-Spend Problem.** Two operations run at the same time and step on each other: a balance goes wrong, or a safety rule is broken. We reproduce each bug deterministically, then fix it.

---

## The three YSQL isolation levels

| Level | What a transaction sees | Anomalies prevented | Anomalies still possible |
|---|---|---|---|
| **READ COMMITTED** | The latest committed data, re-read at the **start of each statement** | Dirty reads | Non-repeatable reads, phantom reads, **lost update** (read-modify-write), write skew |
| **REPEATABLE READ** (a.k.a. **SNAPSHOT**) | One consistent **snapshot** taken at the first statement, for the whole transaction | Dirty / non-repeatable / phantom reads | **Write skew** |
| **SERIALIZABLE** | As if all transactions ran **one after another** | Everything above | None — the engine raises **`40001`** instead |

Set the level per transaction with `BEGIN ISOLATION LEVEL <level>;`, or as a session/database default with `SET default_transaction_isolation = '<level>'`.

> By default YugabyteDB maps `READ COMMITTED` to snapshot isolation. This devcontainer starts the tserver with the gflag **`yb_enable_read_committed_isolation=true`**, so `READ COMMITTED` behaves like true PostgreSQL read-committed (per-statement snapshots + automatic statement retries). It's a server-side flag (set in the devcontainer's `postStartCommand`), not a session GUC — the session default level it produces is visible with:
>
> ```bash
> ysqlsh -h 127.0.0.1 -c "SHOW default_transaction_isolation;"   -- read committed
> ```

---

## The database is ready when the container starts

The devcontainer's `postStartCommand` starts a single-node cluster **and** runs [`setup.sql`](setup.sql), so the moment DevPod / Codespaces finishes you have:

- `accounts` — one row: **Alice = 1000**, with a `CHECK (balance >= 0)` so overdrafts are rejected.
- `oncall` — two doctors, **Alice and Bob both on call**. Business rule: at least one must always stay on call.

```bash
ysqlsh -h 127.0.0.1 -c "SELECT * FROM accounts; SELECT * FROM oncall;"
```

---

## Two ways to run this

| Option | How |
|---|---|
| **Guided demo** | **Terminal → Run Task → `txn-demo`**, then `bash prompt.sh`. Auto-types each step; the concurrent scenarios run in one terminal and print both sessions' transcripts. |
| **Manual workshop** | Open **two** YSQL shells — **Terminal → Run Task → `ysql-a`** and **`ysql-b`** — and run the statements below side by side, so you drive the interleaving yourself. |

The guided demo uses [`concurrency.sh`](concurrency.sh), which runs **Session A** in the background (holding a transaction open with `pg_sleep`) and **Session B** in the foreground, so every run is deterministic. The manual workshop below lets you feel the timing yourself in two shells.

---

## Workshop

Throughout, **A** = the `ysql-a` shell, **B** = the `ysql-b` shell. Reset to the baseline between parts:

```bash
ysqlsh -h 127.0.0.1 -f init-txn/reset.sql
```

### Part 1 — Lost update (READ COMMITTED, no locking)

The app reads the balance, computes the new value, and writes it back. Run the two transactions interleaved — **A** first, then **B**, then finish **A**:

**A** — read, but don't commit yet:

```sql
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance FROM accounts WHERE id = 1;          -- reads 1000
```

**B** — read and complete a 200 withdrawal:

```sql
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance FROM accounts WHERE id = 1;          -- also reads 1000
UPDATE accounts SET balance = 1000 - 200 WHERE id = 1;   -- app computed 800
COMMIT;
```

**A** — finish a 600 withdrawal using the value it read earlier:

```sql
UPDATE accounts SET balance = 1000 - 600 WHERE id = 1;   -- app computed 400
COMMIT;
```

```bash
ysqlsh -h 127.0.0.1 -c "SELECT balance FROM accounts WHERE id = 1;"
```

Final balance is **400**, not **200**. Two withdrawals (600 + 200) but the balance only fell by 600 — **B's withdrawal was silently overwritten**. That's a *lost update*. (Note: the single-statement form `UPDATE ... SET balance = balance - 600` is atomic and *safe*; the bug is in the read-then-write-in-the-app pattern.)

### Part 2 — The fix: `SELECT ... FOR UPDATE`

Lock the row when you read it. Reset, then repeat — but both reads now use `FOR UPDATE`:

**A**:

```sql
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;   -- locks the row, reads 1000
```

**B** — this read now **blocks** until A commits:

```sql
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;   -- waits for A...
```

**A** — write and release the lock:

```sql
UPDATE accounts SET balance = 1000 - 600 WHERE id = 1;
COMMIT;
```

Now **B** unblocks, sees the fresh balance **400**, and completes correctly:

```sql
-- B's SELECT returned 400
UPDATE accounts SET balance = 400 - 200 WHERE id = 1;
COMMIT;
```

Final balance **200** — correct. `FOR UPDATE` made the two readers take turns on the row.

### Part 3 — Write skew (REPEATABLE READ / SNAPSHOT)

Locking one row only helps when both transactions touch the *same* row. Here each transaction reads a **set** of rows and writes a **different** one. Reset, then:

**A**:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT doctor FROM oncall WHERE is_oncall;          -- sees Alice + Bob (2) → safe to go off
```

**B**:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT doctor FROM oncall WHERE is_oncall;          -- also sees 2 → safe to go off
UPDATE oncall SET is_oncall = false WHERE doctor = 'Bob';
COMMIT;
```

**A**:

```sql
UPDATE oncall SET is_oncall = false WHERE doctor = 'Alice';
COMMIT;
```

```bash
ysqlsh -h 127.0.0.1 -c "SELECT count(*) AS on_call FROM oncall WHERE is_oncall;"
```

Both committed and now **nobody is on call**. Each saw a consistent snapshot of `2` and changed a *different* row, so snapshot isolation never noticed the conflict. This is **write skew**.

### Part 4 — Serializable prevents it

Reset, then run the **same** scenario at `SERIALIZABLE` in both shells (A reads rows, B reads rows + commits, then A commits). One of the two transactions fails — the exact message depends on timing, but it's always a **retryable serialization-class error**:

```
ERROR:  could not serialize access due to read/write dependencies among transactions   (SQLSTATE 40001)
-- or, because YugabyteDB resolves conflicts with wait queues, it may surface as:
ERROR:  deadlock detected   (SQLSTATE 40P01)
```

```bash
ysqlsh -h 127.0.0.1 -c "SELECT count(*) AS on_call FROM oncall WHERE is_oncall;"
```

One transaction rolls back, so exactly one doctor stays on call (`on_call = 1`). SERIALIZABLE tracks the read/write dependency and refuses the unsafe commit. (Reading the **rows** — `SELECT doctor ...` rather than `count(*)` — matters: an aggregate can be pushed down without recording the row-level read that the conflict check needs.)

### Part 5 — The retry loop every app needs

A serialization failure (`40001`) or deadlock (`40P01`) is **not** fatal — it's the engine telling you to **try again**. Every application that uses YugabyteDB must wrap its transactions in a retry loop:

```python
# pseudocode — retry on serialization-class failures
for attempt in range(MAX_RETRIES):
    try:
        with conn.transaction(isolation="serializable"):
            do_work()                    # reads + writes
        break                            # committed
    except (SerializationFailure,        # SQLSTATE 40001
            DeadlockDetected):           # SQLSTATE 40P01
        backoff(attempt)                 # exponential backoff, then retry
```

On retry the transaction starts fresh against the current state, so it succeeds once the conflicting transaction has finished. The guided demo (`bash concurrency.sh retry`) shows a real conflict-then-retry: two operations lock the same two rows in opposite order and deadlock, the loser is rolled back, and the application's retry then completes successfully.

---

## YugabyteDB-specific: distributed concurrency control

Everything above is standard SQL isolation. What makes it *distributed* in YugabyteDB:

### Wait-on-Conflict vs Fail-on-Conflict + transaction priorities

PostgreSQL has exactly one strategy: a conflicting transaction **waits**, and a cycle becomes a deadlock. YugabyteDB has **two** conflict-resolution modes:

- **Wait-on-Conflict** (the default in this build) — transactions queue and wait. This is *why* the Part 4 serialization conflict above surfaced as **`deadlock detected` (40P01)** rather than `could not serialize` (40001).
- **Fail-on-Conflict** — the conflict is resolved immediately by **transaction priority**: the lower-priority transaction is aborted so the higher-priority one proceeds without waiting.

Every YugabyteDB transaction carries a priority in `[0,1]`. Bias it per session and read it back:

```bash
ysqlsh -h 127.0.0.1 -c "
SET yb_transaction_priority_lower_bound = 0.9;       -- make this session high-priority
BEGIN;
  SELECT doctor FROM oncall WHERE doctor = 'Alice' FOR UPDATE;
  SELECT yb_get_current_transaction_priority();      -- e.g. 0.96… (High priority transaction)
COMMIT;"
```

| Knob | Purpose |
|---|---|
| `yb_transaction_priority_lower_bound` / `yb_transaction_priority_upper_bound` | Bound the random priority assigned to this session's transactions (`0`–`1`) |
| `yb_transaction_priority` (read-only `SHOW`) | The priority of the current transaction |
| `yb_get_current_transaction_priority()` | Same, as a function (with a `Normal`/`High priority` label) |

Use this to make a critical job (say, a payment) win conflicts against bulk/background work. Under Wait-on-Conflict the priority acts as a tie-breaker; under Fail-on-Conflict it decides the winner outright.

### The distributed lock manager — `yb_lock_status()`

PostgreSQL keeps locks in one server's shared memory (`pg_locks`). YugabyteDB locks live in the **tablet that owns the row**, as **provisional intent records** tagged with the distributed transaction id. Inspect them while a transaction holds a row — open two shells (`ysql-a`, `ysql-b`):

**A** — lock a row and hold it:

```sql
BEGIN;
SELECT doctor FROM oncall WHERE doctor = 'Alice' FOR UPDATE;   -- leave open
```

**B** — read the lock manager:

```sql
SELECT locktype, mode, granted, is_explicit, hash_cols,
       left(tablet_id, 12) AS tablet, left(transaction_id::text, 8) AS txn
FROM   yb_lock_status(null, null)
WHERE  relation = 'oncall'::regclass;
```

```
 locktype |            mode            | granted | is_explicit |   hash_cols   |    tablet    |   txn
----------+----------------------------+---------+-------------+---------------+--------------+----------
 relation | {WEAK_READ,WEAK_WRITE}     | t       | f           |               | 8821a35a873e | e692f027
 row      | {STRONG_READ,STRONG_WRITE} | t       | t           | {"Alice"}     | 8821a35a873e | e692f027
```

- The **`row`** lock (`is_explicit = t`, `{STRONG_READ,STRONG_WRITE}`) is your `FOR UPDATE` on Alice's row.
- The **`relation`** lock (`{WEAK_READ,WEAK_WRITE}`) is the table-level intent that guards it.
- `tablet` and `txn` show the locks are **per-tablet** and keyed by the **distributed transaction id** — concepts `pg_locks` doesn't have because its locks never leave a single process.

(The guided demo runs this as `bash concurrency.sh yb-locks`.) Finish with `COMMIT;`/`ROLLBACK;` in shell A to release.

---

## Locking reference

`SELECT ... FOR ...` takes an explicit row lock; the four strengths (weakest → strongest):

| Clause | Use it to |
|---|---|
| `FOR KEY SHARE` | Block deletes/key changes of a row you depend on (e.g. an FK parent) |
| `FOR SHARE` | Let others read but not modify the row |
| `FOR NO KEY UPDATE` | Update non-key columns; allows concurrent `FOR KEY SHARE` |
| `FOR UPDATE` | Exclusive — the read-modify-write pattern from Part 2 |

By default a lock request **waits** for the holder (YugabyteDB uses wait queues). Override that per statement with `NOWAIT` or `SKIP LOCKED`:

```sql
SELECT ... FOR UPDATE NOWAIT;        -- error immediately instead of waiting
SELECT ... FOR UPDATE SKIP LOCKED;   -- skip already-locked rows (queue pattern)
```

---

## Manual reference

```bash
# Re-run the bootstrap (idempotent — recreates the demo tables)
ysqlsh -h 127.0.0.1 -f init-txn/setup.sql

# Reset balances / roster to the baseline between scenarios
ysqlsh -h 127.0.0.1 -f init-txn/reset.sql

# Open a YSQL shell
ysqlsh -h 127.0.0.1

# Inspect in-flight transactions and locks
ysqlsh -h 127.0.0.1 -c "SELECT * FROM pg_locks WHERE NOT granted;"
ysqlsh -h 127.0.0.1 -c "SELECT * FROM yb_lock_status(null, null);"

# Show / change the session default isolation level
ysqlsh -h 127.0.0.1 -c "SHOW default_transaction_isolation;"
```

Run any single concurrent scenario directly:

```bash
cd init-txn
bash concurrency.sh lost-update    # or: for-update | write-skew | serializable | retry
```

---

## Reference

- [Transactions in YugabyteDB — docs](https://docs.yugabyte.com/stable/architecture/transactions/)
- [Isolation levels](https://docs.yugabyte.com/stable/architecture/transactions/isolation-levels/)
- [Explicit locking (`SELECT ... FOR UPDATE`)](https://docs.yugabyte.com/stable/explore/transactions/explicit-locking/)
- [Read Committed isolation](https://docs.yugabyte.com/stable/architecture/transactions/read-committed/)
- [Designing applications with retry logic](https://docs.yugabyte.com/stable/develop/learn/transactions/transactions-retries-ysql/)
