#!/bin/bash
#
# thread-watch.sh - sample JVM thread / GC / sync-queue health inside an Exalate node pod and
# capture thread dumps (jcmd Thread.print) when the node shows signs of backing up.
#
# Companion to mem-watch.sh. Run it from a shell already inside the pod.
#
#   ./thread-watch.sh                 start sampling (foreground; use nohup ... & for background)
#   ./thread-watch.sh capture         take one dump set now (3 dumps, 10 s apart) and exit
#   ./thread-watch.sh analyze FILE..  print the summary of existing dump file(s) (.txt or .txt.gz)
#
# A dump set is taken when ANY of these fires (and the cooldown has passed):
#   - live JVM thread count (nlwp) >= NLWP_THRESHOLD
#   - AskTimeoutException count in the node log during the last interval >= ASK_THRESHOLD
#   - inbound sync requests that arrived minus those that started during the interval >= BACKLOG_THRESHOLD
#   - PERIODIC_EVERY seconds passed since the last dump set (0 disables)
#   - someone ran:  touch "$OUT_DIR/CAPTURE_NOW"
#
# Nothing here prints the java command line: start-jcloudnode.sh passes the DB password as a -D flag.
#
# Every setting is an environment variable:
OUT_DIR="${OUT_DIR:-/opt/jcloudnode/data/logs/thread-watch}"
NODE_LOG="${NODE_LOG:-/opt/jcloudnode/data/logs/jcloudnode.log}"   # node log to watch for signals
INTERVAL="${INTERVAL:-30}"                  # seconds between samples
NLWP_THRESHOLD="${NLWP_THRESHOLD:-400}"     # live threads that trigger a dump set
ASK_THRESHOLD="${ASK_THRESHOLD:-20}"        # AskTimeoutExceptions per interval that trigger a dump set
BACKLOG_THRESHOLD="${BACKLOG_THRESHOLD:-15}" # (arrived - started) per interval that triggers a dump set
PERIODIC_EVERY="${PERIODIC_EVERY:-1800}"    # also dump every N seconds regardless; 0 = off
COOLDOWN="${COOLDOWN:-300}"                 # min seconds between triggered dump sets
DUMPS_PER_SET="${DUMPS_PER_SET:-3}"
DUMP_GAP="${DUMP_GAP:-10}"                  # seconds between dumps inside a set
MAX_SETS="${MAX_SETS:-40}"                  # keep at most this many dump sets (oldest deleted)
MIN_FREE_MB="${MIN_FREE_MB:-500}"           # skip dumps when the volume has less free space than this

SAMPLES="$OUT_DIR/samples.log"
SUMMARY="$OUT_DIR/summary.log"
STATE="$OUT_DIR/.log-offset"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

find_pid() { pgrep -o java 2>/dev/null; }

# jcmd/jstat must run as the user that owns the JVM (jcloud), not as root.
as_jvm_user() {
  local pid="$1"; shift
  local owner; owner="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [ "$(id -u)" = "0" ] && [ -n "$owner" ] && [ "$owner" != "root" ]; then
    runuser -u "$owner" -- "$@"
  else
    "$@"
  fi
}

# Live JVM thread count: /proc on Linux (pods), ps as a fallback.
nlwp_of() {
  if [ -d "/proc/$1/task" ]; then ls "/proc/$1/task" | wc -l | tr -d ' '
  else ps -M -p "$1" 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' '; fi   # macOS (local testing only)
}

free_mb() { df -Pm "$OUT_DIR" 2>/dev/null | awk 'NR==2{print $4}'; }

# ---------------------------------------------------------------------------------------------
# Summarise one Thread.print dump: threads per pool and state, plus where blocked threads wait.
# ---------------------------------------------------------------------------------------------
summarize() {
  local f="$1" cat_cmd="cat"
  case "$f" in *.gz) cat_cmd="gzip -dc" ;; esac
  echo "---- $(basename "$f")"
  $cat_cmd "$f" | awk '
    function pool(n) { sub(/[-#]?[0-9]+$/, "", n); return n }
    function flush() {
      if (name == "") return
      p = pool(name); total++; cnt[p]++; st[p "|" state]++
      if (waitframe != "") { blk[p]++; where[p " <- " (blocking == "" ? "(no app frame)" : blocking)]++ }
      name = ""; state = "?"; blocking = ""; appframe = ""; waitframe = ""
    }
    /^"/ {
      flush()
      name = $0; sub(/^"/, "", name); sub(/".*/, "", name); state = "?"; next
    }
    /java.lang.Thread.State:/ { state = $2; next }
    /^\tat / {
      fr = $2
      # A thread is "blocking on a future" if its stack waits in Await / managedBlock / resultInf.
      if (fr ~ /scala\.concurrent\.Await|ForkJoinPool\.managedBlock|FutureUtils\.result|Promise\$DefaultPromise\.tryAwait|CompletableFuture\.get|FutureTask\.get/) waitframe = fr
      # First application frame below the wait = the code that asked to block.
      if (waitframe != "" && blocking == "" && fr !~ /^(java\.|jdk\.|sun\.|scala\.|akka\.|play\.|com\.typesafe|com\.exalate\.services\.utils\.FutureUtils)/) {
        sub(/\(.*/, "", fr); blocking = fr
      }
      next
    }
    END {
      flush()
      printf "threads_total=%d\n", total
      printf "%-48s %6s %9s %8s %8s %13s %15s\n", "pool", "count", "RUNNABLE", "BLOCKED", "WAITING", "TIMED_WAITING", "await-blocking"
      n = 0
      for (p in cnt) keys[++n] = p
      # sort pools by count desc (simple insertion sort, n is small)
      for (i = 2; i <= n; i++) { k = keys[i]; j = i - 1; while (j > 0 && cnt[keys[j]] < cnt[k]) { keys[j+1] = keys[j]; j-- } keys[j+1] = k }
      for (i = 1; i <= n && i <= 25; i++) {
        p = keys[i]
        printf "%-48s %6d %9d %8d %8d %13d %15d\n", substr(p, 1, 48), cnt[p], st[p "|RUNNABLE"], st[p "|BLOCKED"], st[p "|WAITING"], st[p "|TIMED_WAITING"], blk[p]
      }
      m = 0
      for (w in where) wk[++m] = w
      for (i = 2; i <= m; i++) { k = wk[i]; j = i - 1; while (j > 0 && where[wk[j]] < where[k]) { wk[j+1] = wk[j]; j-- } wk[j+1] = k }
      if (m > 0) print "threads blocked waiting on a future, by pool <- Exalate caller:"
      for (i = 1; i <= m && i <= 15; i++) printf "  %5d  %s\n", where[wk[i]], wk[i]
    }'
}

# ---------------------------------------------------------------------------------------------
# Take one dump set.
# ---------------------------------------------------------------------------------------------
capture() {
  local reason="$1" pid; pid="$(find_pid)"
  if [ -z "$pid" ]; then echo "$(ts) capture skipped: java process not found" >> "$SUMMARY"; return 1; fi
  local free; free="$(free_mb)"
  if [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_MB" ]; then
    echo "$(ts) capture skipped: only ${free} MB free on $OUT_DIR (MIN_FREE_MB=$MIN_FREE_MB)" >> "$SUMMARY"; return 1
  fi
  local set; set="$(date -u +%Y%m%dT%H%M%SZ)"
  echo "==== $(ts) dump set $set  reason: $reason" >> "$SUMMARY"
  local i=1
  while [ "$i" -le "$DUMPS_PER_SET" ]; do
    local f="$OUT_DIR/td-${set}-${i}.txt"
    {
      echo "# thread dump $i/$DUMPS_PER_SET  set=$set  taken=$(ts)  reason: $reason"
      echo "# nlwp=$(nlwp_of "$pid")  cpu=$(ps -o %cpu= -p "$pid" | tr -d ' ')"
      as_jvm_user "$pid" jcmd "$pid" Thread.print -l 2>&1
    } > "$f"
    summarize "$f" >> "$SUMMARY" 2>&1
    gzip -f "$f"
    i=$((i + 1))
    [ "$i" -le "$DUMPS_PER_SET" ] && sleep "$DUMP_GAP"
  done
  # GC/heap context for the set, once.
  { echo "gc (jstat -gcutil):"; as_jvm_user "$pid" jstat -gcutil "$pid" 2>&1; } >> "$SUMMARY"
  # Retention: keep the newest MAX_SETS sets.
  local sets; sets="$(ls -1 "$OUT_DIR"/td-*-1.txt.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$sets" -gt "$MAX_SETS" ] && ls -1 "$OUT_DIR"/td-*-1.txt.gz | sort | head -n "$((sets - MAX_SETS))" | while read -r old; do
    rm -f "${old%-1.txt.gz}"-*.txt.gz
  done
}

# ---------------------------------------------------------------------------------------------
# Count signals in the node log written since the previous sample.
# Sets: ASK ARRIVED STARTED  (all 0 when the log is missing)
# ---------------------------------------------------------------------------------------------
read_log_delta() {
  ASK=0; ARRIVED=0; STARTED=0
  [ -f "$NODE_LOG" ] || return 0
  local size off
  size="$(wc -c < "$NODE_LOG" | tr -d ' ')"
  off="$(cat "$STATE" 2>/dev/null || echo "$size")"   # first run: start at the end of the log
  [ "$size" -lt "$off" ] && off=0                      # log rotated: read the new file from the start
  if [ "$size" -gt "$off" ]; then
    eval "$(tail -c "+$((off + 1))" "$NODE_LOG" | awk '
      /AskTimeoutException: Ask timed out/                    { a++ }
      /Creating a sync request and context for remote event/  { r++ }
      /Processing request [0-9]+ of type .* on state READY /  { s++ }
      END { printf "ASK=%d; ARRIVED=%d; STARTED=%d\n", a, r, s }')"
  fi
  echo "$size" > "$STATE"
}

# ---------------------------------------------------------------------------------------------
main_loop() {
  echo "==== thread-watch started $(ts) interval=${INTERVAL}s nlwp>=${NLWP_THRESHOLD} ask>=${ASK_THRESHOLD} backlog>=${BACKLOG_THRESHOLD} periodic=${PERIODIC_EVERY}s cooldown=${COOLDOWN}s ====" | tee -a "$SAMPLES" >> "$SUMMARY"
  local last_capture=0 last_periodic; last_periodic="$(date +%s)"
  local hdr_every=40 n=0
  # Baseline set at start, so there is a "healthy" dump to compare against.
  capture "baseline at start"; last_capture="$(date +%s)"
  while true; do
    local pid now nlwp cpu gc reason=""
    pid="$(find_pid)"; now="$(date +%s)"
    read_log_delta
    if [ -n "$pid" ]; then
      nlwp="$(nlwp_of "$pid")"
      cpu="$(ps -o %cpu= -p "$pid" | tr -d ' ')"
      # S0 S1 E O M CCS YGC YGCT FGC FGCT CGC CGCT GCT -> keep O(ld) %, young/full GC counts, total GC time
      gc="$(as_jvm_user "$pid" jstat -gcutil "$pid" 2>/dev/null | awk 'NR==2{printf "old=%s%% ygc=%s fgc=%s gct=%ss", $4, $7, $9, $NF}')"
    else
      nlwp="-"; cpu="-"; gc="java-not-found"
    fi
    [ $((n % hdr_every)) -eq 0 ] && echo "# time  pid  nlwp  cpu%  arrived started backlog  ask_timeouts  gc" >> "$SAMPLES"
    n=$((n + 1))
    echo "$(ts) pid=${pid:--} nlwp=$nlwp cpu=$cpu arrived=$ARRIVED started=$STARTED backlog=$((ARRIVED - STARTED)) ask=$ASK $gc" >> "$SAMPLES"

    if [ -n "$pid" ]; then
      [ "$nlwp" != "-" ] && [ "$nlwp" -ge "$NLWP_THRESHOLD" ] && reason="nlwp=$nlwp>=$NLWP_THRESHOLD"
      [ "$ASK" -ge "$ASK_THRESHOLD" ] && reason="${reason:+$reason, }ask_timeouts=$ASK>=$ASK_THRESHOLD"
      [ $((ARRIVED - STARTED)) -ge "$BACKLOG_THRESHOLD" ] && reason="${reason:+$reason, }backlog=$((ARRIVED - STARTED))>=$BACKLOG_THRESHOLD"
      if [ -f "$OUT_DIR/CAPTURE_NOW" ]; then rm -f "$OUT_DIR/CAPTURE_NOW"; reason="${reason:+$reason, }manual"; last_capture=0; fi
      if [ -n "$reason" ] && [ $((now - last_capture)) -ge "$COOLDOWN" ]; then
        capture "$reason"; last_capture="$(date +%s)"; last_periodic="$last_capture"
      elif [ "$PERIODIC_EVERY" -gt 0 ] && [ $((now - last_periodic)) -ge "$PERIODIC_EVERY" ]; then
        capture "periodic"; last_capture="$(date +%s)"; last_periodic="$last_capture"
      fi
    fi
    sleep "$INTERVAL"
  done
}

mkdir -p "$OUT_DIR"
case "${1:-run}" in
  run)     main_loop ;;
  capture) capture "manual (capture command)"; echo "dumps and summary in $OUT_DIR" ;;
  analyze) shift; for f in "$@"; do summarize "$f"; done ;;
  *)       echo "usage: $0 [run|capture|analyze FILE...]"; exit 2 ;;
esac
