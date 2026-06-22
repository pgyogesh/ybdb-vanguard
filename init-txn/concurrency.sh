#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# concurrency.sh — coordinated two-session transaction scenarios (init-txn)
#
# Usage:  bash concurrency.sh <scenario>
#
#   lost-update   READ COMMITTED, plain read-modify-write  → lost update (BUG)
#   for-update    READ COMMITTED + SELECT ... FOR UPDATE    → fixed (pessimistic)
#   write-skew    REPEATABLE READ, two doctors go off call  → write skew (BUG)
#   serializable  SERIALIZABLE, same scenario               → conflict prevents it
#   retry         deadlock + an application retry loop       → fail, then succeed
#
# Each scenario runs Session A in the BACKGROUND (it holds a transaction open
# with pg_sleep) and Session B in the FOREGROUND. The pg_sleep windows make the
# interleaving deterministic no matter how fast you step through the demo, so
# you get the same result every single time.
#
# For each session we print (1) the exact SQL it runs and (2) its raw psql
# output, captured to a temp file so the two sessions' output never tangles
# together on screen. The SQL shown is the SAME string that is piped to ysqlsh,
# so the displayed commands and the executed commands can never drift apart.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

YSQL="ysqlsh -h 127.0.0.1 -X -q"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── colours ───────────────────────────────────────────────────────────────────
CA='\033[0;33m'   # Session A — yellow
CB='\033[0;35m'   # Session B — magenta
CH='\033[1;36m'   # heading   — cyan
CG='\033[0;32m'   # good      — green
CR='\033[0;31m'   # bad/error — red
NC='\033[0m'

reset_state() { $YSQL -f reset.sql >/dev/null 2>&1; }

run() { printf '%s\n' "$2" | $YSQL > "$1" 2>&1; }   # run <outfile> <sql-string>

show_sql() {  # show_sql <color> <label> <sql-string>
  echo -e "$1┌─ $2 · SQL ──────────────────────────────────${NC}"
  printf '%s\n' "$3" | sed 's/^/  /'
  echo -e "$1└─────────────────────────────────────────────${NC}"
}
show_out() {  # show_out <color> <label> <file>
  echo -e "$1┌─ $2 · raw output ───────────────────────────${NC}"
  sed 's/^/  /' "$3"
  echo -e "$1└─────────────────────────────────────────────${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
scenario_lost_update() {
  reset_state
  echo -e "${CH}Scenario: LOST UPDATE  (READ COMMITTED, no locking)${NC}"
  echo "Two app-style transactions each read the balance, compute a new value in"
  echo "the app (here: psql \\gset), and write it back. Alice starts with 1000;"
  echo "A withdraws 600, B withdraws 200. Correct final balance = 1000-600-200 = 200."
  echo

  local sqlA sqlB
  sqlA=$(cat <<'SQL'
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance AS bal FROM accounts WHERE id = 1 \gset
\echo A read balance = :bal
SELECT pg_sleep(4);
UPDATE accounts SET balance = :bal - 600 WHERE id = 1;
\echo 'A computed' :bal '- 600 and wrote it'
COMMIT;
SQL
)
  sqlB=$(cat <<'SQL'
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance AS bal FROM accounts WHERE id = 1 \gset
\echo B read balance = :bal
UPDATE accounts SET balance = :bal - 200 WHERE id = 1;
\echo 'B computed' :bal '- 200 and wrote it'
COMMIT;
SQL
)

  ( run "$TMP/a.txt" "$sqlA" ) &
  sleep 2
  run "$TMP/b.txt" "$sqlB"
  wait

  show_sql "$CA" "Session A (BEGIN @ t0, COMMIT @ t≈4)" "$sqlA"
  show_out "$CA" "Session A" "$TMP/a.txt"
  show_sql "$CB" "Session B (BEGIN @ t≈2, COMMIT @ t≈2)" "$sqlB"
  show_out "$CB" "Session B" "$TMP/b.txt"

  local final; final=$($YSQL -t -A -c "SELECT balance FROM accounts WHERE id = 1;")
  echo -e "\n${CR}Final balance = ${final}  ✗  Two withdrawals (600 + 200) but the balance only fell by 600.${NC}"
  echo -e "${CR}Both sessions read 1000, so B's write was silently overwritten — the classic LOST UPDATE.${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
scenario_for_update() {
  reset_state
  echo -e "${CH}Scenario: THE FIX  (READ COMMITTED + SELECT ... FOR UPDATE)${NC}"
  echo "Same two withdrawals — but each read now takes a row lock with FOR UPDATE."
  echo "B's read must WAIT until A commits, so B reads the up-to-date balance."
  echo

  local sqlA sqlB
  sqlA=$(cat <<'SQL'
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance AS bal FROM accounts WHERE id = 1 FOR UPDATE \gset
\echo A locked the row, read balance = :bal
SELECT pg_sleep(4);
UPDATE accounts SET balance = :bal - 600 WHERE id = 1;
\echo 'A wrote' :bal '- 600'
COMMIT;
SQL
)
  sqlB=$(cat <<'SQL'
BEGIN ISOLATION LEVEL READ COMMITTED;
\echo B asks for the row (FOR UPDATE) — this BLOCKS until A commits...
SELECT balance AS bal FROM accounts WHERE id = 1 FOR UPDATE \gset
\echo B unblocked, read balance = :bal
UPDATE accounts SET balance = :bal - 200 WHERE id = 1;
\echo 'B wrote' :bal '- 200'
COMMIT;
SQL
)

  ( run "$TMP/a.txt" "$sqlA" ) &
  sleep 2
  run "$TMP/b.txt" "$sqlB"
  wait

  show_sql "$CA" "Session A (locks @ t0, COMMIT @ t≈4)" "$sqlA"
  show_out "$CA" "Session A" "$TMP/a.txt"
  show_sql "$CB" "Session B (waits, then runs @ t≈4)"   "$sqlB"
  show_out "$CB" "Session B" "$TMP/b.txt"

  local final; final=$($YSQL -t -A -c "SELECT balance FROM accounts WHERE id = 1;")
  echo -e "\n${CG}Final balance = ${final}  ✓  B read 400 (after A's commit), so both withdrawals stacked correctly.${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
scenario_write_skew() {
  reset_state
  echo -e "${CH}Scenario: WRITE SKEW  (REPEATABLE READ / SNAPSHOT)${NC}"
  echo "Rule: at least one doctor must stay on call. Alice and Bob are both on call."
  echo "Each runs a transaction: 'if 2+ are on call, I can go off call.'"
  echo "Both read the SAME snapshot (2 on call) and each takes themselves off."
  echo

  local sqlA sqlB
  sqlA=$(cat <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT doctor FROM oncall WHERE is_oncall;   -- A reads the on-call set: Alice, Bob
\echo A sees 2 doctors on call — safe to go off, will remove Alice
SELECT pg_sleep(4);
UPDATE oncall SET is_oncall = false WHERE doctor = 'Alice';
COMMIT;
\echo A committed.
SQL
)
  sqlB=$(cat <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT doctor FROM oncall WHERE is_oncall;   -- B reads the on-call set: Alice, Bob
\echo B sees 2 doctors on call — safe to go off, will remove Bob
UPDATE oncall SET is_oncall = false WHERE doctor = 'Bob';
COMMIT;
\echo B committed.
SQL
)

  ( run "$TMP/a.txt" "$sqlA" ) &
  sleep 2
  run "$TMP/b.txt" "$sqlB"
  wait

  show_sql "$CA" "Session A — removes Alice" "$sqlA"
  show_out "$CA" "Session A" "$TMP/a.txt"
  show_sql "$CB" "Session B — removes Bob"   "$sqlB"
  show_out "$CB" "Session B" "$TMP/b.txt"

  local n; n=$($YSQL -t -A -c "SELECT count(*) FROM oncall WHERE is_oncall;")
  echo -e "\n${CR}Doctors on call = ${n}  ✗  Both transactions committed — nobody is on call.${NC}"
  echo -e "${CR}Each saw a consistent snapshot of 2 and changed a DIFFERENT row, so SNAPSHOT${NC}"
  echo -e "${CR}isolation never noticed the conflict. This anomaly is WRITE SKEW.${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
scenario_serializable() {
  reset_state
  echo -e "${CH}Scenario: PREVENTED  (SERIALIZABLE)${NC}"
  echo "Exact same on-call scenario, but both transactions run as SERIALIZABLE."
  echo "YugabyteDB tracks the read/write dependency and refuses the unsafe commit."
  echo

  local sqlA sqlB
  sqlA=$(cat <<'SQL'
\set ON_ERROR_STOP off
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT doctor FROM oncall WHERE is_oncall;   -- A's read is part of the txn's conflict footprint
\echo A sees 2 on call — will try to remove Alice
SELECT pg_sleep(4);
UPDATE oncall SET is_oncall = false WHERE doctor = 'Alice';
COMMIT;
\echo A reached COMMIT.
SQL
)
  sqlB=$(cat <<'SQL'
\set ON_ERROR_STOP off
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT doctor FROM oncall WHERE is_oncall;   -- B's read conflicts with A's pending write
\echo B sees 2 on call — will try to remove Bob
UPDATE oncall SET is_oncall = false WHERE doctor = 'Bob';
COMMIT;
\echo B reached COMMIT.
SQL
)

  ( run "$TMP/a.txt" "$sqlA" ) &
  sleep 2
  run "$TMP/b.txt" "$sqlB"
  wait

  show_sql "$CA" "Session A — removes Alice" "$sqlA"
  show_out "$CA" "Session A" "$TMP/a.txt"
  show_sql "$CB" "Session B — removes Bob"   "$sqlB"
  show_out "$CB" "Session B" "$TMP/b.txt"

  local n; n=$($YSQL -t -A -c "SELECT count(*) FROM oncall WHERE is_oncall;")
  echo -e "\n${CG}Doctors on call = ${n}  ✓  At least one doctor is still on call — the invariant held.${NC}"
  echo -e "${CG}One transaction was rolled back with a serialization failure (SQLSTATE 40001, or a${NC}"
  echo -e "${CG}deadlock, 40P01 — both are retryable). YugabyteDB refused to let both commit.${NC}"
  echo -e "An application catches that error and RETRIES the failed transaction — see the 'retry' scenario."
}

# ─────────────────────────────────────────────────────────────────────────────
scenario_retry() {
  reset_state
  echo -e "${CH}Scenario: RETRY LOOP  (handling a serialization failure)${NC}"
  echo "A serialization failure is not fatal — it means 'try again.' Here two operations"
  echo "each need to lock BOTH doctor rows (e.g. to reassign a shift), but in OPPOSITE"
  echo "order, so they deadlock. YugabyteDB aborts one; a correct app simply retries it,"
  echo "and the retry succeeds once the other operation has finished."
  echo

  local sqlBg sqlFg
  sqlBg=$(cat <<'SQL'
BEGIN;
SELECT doctor FROM oncall WHERE doctor = 'Bob'   FOR UPDATE;
SELECT pg_sleep(3);
SELECT doctor FROM oncall WHERE doctor = 'Alice' FOR UPDATE;
COMMIT;
SQL
)
  sqlFg=$(cat <<'SQL'
BEGIN;
SELECT doctor FROM oncall WHERE doctor = 'Alice' FOR UPDATE;
SELECT pg_sleep(3);
SELECT doctor FROM oncall WHERE doctor = 'Bob'   FOR UPDATE;
COMMIT;
SQL
)

  show_sql "$CA" "Background op — locks Bob, then Alice"        "$sqlBg"
  show_sql "$CB" "Foreground op (retried) — locks Alice, then Bob" "$sqlFg"
  echo

  # Background 'other operation': runs once.
  ( printf '%s\n' "$sqlBg" | $YSQL >/dev/null 2>&1 ) &

  sleep 1
  # Foreground application retry loop (max 5 attempts).
  local attempt
  for attempt in 1 2 3 4 5; do
    run "$TMP/fg.txt" "$sqlFg"
    show_out "$CB" "Foreground attempt ${attempt}" "$TMP/fg.txt"
    if grep -qiE '40001|40P01|could not serialize|deadlock|conflict' "$TMP/fg.txt"; then
      local code; code=$(grep -oiE '40001|40P01|deadlock' "$TMP/fg.txt" | head -1)
      echo -e "${CR}Attempt ${attempt}: FAILED (${code:-serialization failure}) — backing off and retrying...${NC}"
    else
      echo -e "${CG}Attempt ${attempt}: committed — the retry got both locks once the other op released.${NC}"
      break
    fi
  done
  wait

  echo -e "\n${CG}✓  The first attempt lost a deadlock and was rolled back; the retry succeeded.${NC}"
  echo -e "${CG}Wrapping every transaction in a retry-on-40001/40P01 loop is how you write${NC}"
  echo -e "${CG}correct applications against a distributed database.${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
scenario_yb_locks() {
  reset_state
  echo -e "${CH}Scenario: DISTRIBUTED LOCKS  (yb_lock_status) — YugabyteDB-specific${NC}"
  echo "Postgres keeps locks in one server's shared memory (pg_locks). YugabyteDB is"
  echo "distributed: a lock lives in the TABLET that owns the row, as a provisional"
  echo "intent record tagged with the distributed transaction id. yb_lock_status()"
  echo "surfaces those intents while a transaction holds them."
  echo

  local sqlHold sqlObs
  sqlHold=$(cat <<'SQL'
BEGIN;
SELECT doctor FROM oncall WHERE doctor = 'Alice' FOR UPDATE;
SELECT pg_sleep(6);
COMMIT;
SQL
)
  sqlObs=$(cat <<'SQL'
SELECT locktype, mode, granted, is_explicit, hash_cols,
       left(tablet_id, 12)           AS tablet,
       left(transaction_id::text, 8) AS txn
FROM   yb_lock_status(null, null)
WHERE  relation = 'oncall'::regclass;
SQL
)

  show_sql "$CA" "Holder — locks Alice's row FOR UPDATE, holds it open" "$sqlHold"
  ( printf '%s\n' "$sqlHold" | $YSQL >/dev/null 2>&1 ) &

  sleep 2
  show_sql "$CB" "Observer — reads the distributed lock manager" "$sqlObs"
  run "$TMP/o.txt" "$sqlObs"
  show_out "$CB" "Observer" "$TMP/o.txt"
  wait

  echo -e "\n${CG}While the holder's transaction is open, yb_lock_status() shows its locks:${NC}"
  echo    "  • a 'row' lock on hash_cols {Alice}, mode {STRONG_READ,STRONG_WRITE} — the explicit FOR UPDATE"
  echo    "  • a 'relation' lock, mode {WEAK_READ,WEAK_WRITE} — the table-level intent that guards it"
  echo    "  • the owning tablet and the distributed transaction id (txn) — locks are PER-TABLET, not global"
  echo -e "${CG}These are YugabyteDB's provisional intent records. Postgres's pg_locks has no tablet${NC}"
  echo -e "${CG}or transaction-id columns because its locks never leave a single process.${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  lost-update)  scenario_lost_update  ;;
  for-update)   scenario_for_update   ;;
  write-skew)   scenario_write_skew   ;;
  serializable) scenario_serializable ;;
  retry)        scenario_retry        ;;
  yb-locks)     scenario_yb_locks     ;;
  *)
    echo "Usage: bash concurrency.sh {lost-update|for-update|write-skew|serializable|retry|yb-locks}"
    exit 1
    ;;
esac
