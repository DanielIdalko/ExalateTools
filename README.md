How to Use mem-watch.sh
--------WARNING--------
mem-watch.sh will continue to write logs until stopped 
or node gets killed, its important to use it ONLY during 
peak app usage windows to monitor real memory preassure.
-----------------------


Run this from the shell already inside the pod.

1. Create the monitor script
cat > /opt/jcloudnode/data/logs/mem-watch.sh <<'EOF'
#!/bin/sh

OUT="/opt/jcloudnode/data/logs/mem-watch.log"
INTERVAL="${1:-60}"

echo "==== mem-watch started $(date -Is), interval=${INTERVAL}s ====" >> "$OUT"

while true; do
  {
    echo "============================================================"
    echo "timestamp=$(date -Is)"

    echo "--- cgroup usage ---"
    if [ -f /sys/fs/cgroup/memory.current ]; then
      echo "cgroup_version=v2"
      echo "memory.current=$(cat /sys/fs/cgroup/memory.current)"
      echo "memory.max=$(cat /sys/fs/cgroup/memory.max)"
      echo "--- memory.events ---"
      cat /sys/fs/cgroup/memory.events 2>/dev/null
      echo "--- memory.stat key fields ---"
      cat /sys/fs/cgroup/memory.stat 2>/dev/null | egrep '^(anon|file|kernel|kernel_stack|pagetables|percpu|sock|shmem|file_mapped|file_dirty|file_writeback|slab|slab_reclaimable|slab_unreclaimable|inactive_anon|active_anon|inactive_file|active_file|unevictable|workingset|pgfault|pgmajfault|oom|oom_kill)'
    elif [ -f /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
      echo "cgroup_version=v1"
      echo "memory.usage_in_bytes=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes)"
      echo "memory.limit_in_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
      echo "memory.failcnt=$(cat /sys/fs/cgroup/memory/memory.failcnt)"
      echo "--- memory.stat key fields ---"
      cat /sys/fs/cgroup/memory/memory.stat 2>/dev/null | egrep '^(rss|cache|mapped_file|pgpgin|pgpgout|pgfault|pgmajfault|inactive_anon|active_anon|inactive_file|active_file|unevictable|hierarchical_memory_limit|total_rss|total_cache|total_mapped_file)'
    else
      echo "No known cgroup memory files found"
    fi

    echo "--- java process ---"
    JAVA_PID="$(pgrep -o java || true)"
    if [ -n "$JAVA_PID" ]; then
      ps -o pid,ppid,%cpu,%mem,rss,vsz,nlwp,etime,comm -p "$JAVA_PID"
    else
      echo "java process not found"
    fi

    echo "--- filesystem tmp usage ---"
    df -h /tmp /dev/shm /opt/jcloudnode/data 2>/dev/null
    du -sh /tmp /dev/shm /opt/jcloudnode/data/logs 2>/dev/null

  } >> "$OUT" 2>&1

  sleep "$INTERVAL"
done
EOF

2. Make it executable
chmod +x /opt/jcloudnode/data/logs/mem-watch.sh
3. Start it in the background

Every 60 seconds:

nohup /opt/jcloudnode/data/logs/mem-watch.sh 60 >/opt/jcloudnode/data/logs/mem-watch.nohup 2>&1 &
4. Confirm it is running
ps aux | grep mem-watch | grep -v grep
5. Confirm logs are being written
tail -n 80 /opt/jcloudnode/data/logs/mem-watch.log
6. Let it run

Because your restart happens every 8–10 days, leave it running continuously.

7. After the next restart, inspect the last samples
tail -n 300 /opt/jcloudnode/data/logs/mem-watch.log

The key fields to check before the restart are:

memory.current
memory.max
anon
file
shmem
slab
oom
oom_kill
rss
cache
8. Optional: reduce log growth

Check size:

du -h /opt/jcloudnode/data/logs/mem-watch.log

If it grows too much, rotate manually:

mv /opt/jcloudnode/data/logs/mem-watch.log /opt/jcloudnode/data/logs/mem-watch-$(date +%F-%H%M).log

Then the running script will recreate mem-watch.log on the next sample.


How to Use thread-watch.sh
--------------------------
thread-watch.sh samples the JVM thread count, GC and the sync queue every
30 s, and takes thread dumps (jcmd Thread.print) when the node starts
backing up. Use it to find out WHERE threads are stuck when sync slows down.
It never prints the java command line, so the DB password stays out of its logs.

Run this from the shell already inside the pod.

1. Copy the script in (from your machine)
kubectl cp thread-watch.sh <namespace>/<pod>:/opt/jcloudnode/data/logs/thread-watch.sh

(or paste it with: cat > /opt/jcloudnode/data/logs/thread-watch.sh <<'EOF' ... EOF)

2. Make it executable and start it in the background
chmod +x /opt/jcloudnode/data/logs/thread-watch.sh
setsid nohup /opt/jcloudnode/data/logs/thread-watch.sh >/opt/jcloudnode/data/logs/thread-watch.nohup 2>&1 &

3. Confirm it is running
ps aux | grep thread-watch | grep -v grep
tail -n 5 /opt/jcloudnode/data/logs/thread-watch/samples.log
head -n 25 /opt/jcloudnode/data/logs/thread-watch/summary.log

Output (in /opt/jcloudnode/data/logs/thread-watch/)

samples.log   one line per interval:
              nlwp (live JVM threads), cpu, arrived/started/backlog of inbound
              sync requests, ask (sync-status AskTimeoutExceptions), old-gen %, GC counts
summary.log   per dump: threads per pool and state, and the threads blocked
              waiting on a future grouped by the code that is waiting
td-*.txt.gz   the raw thread dumps (3 per set, 10 s apart)

A dump set is taken when ANY of these fires (5 min cooldown):
- nlwp >= NLWP_THRESHOLD (default 400)
- AskTimeoutExceptions in one interval >= ASK_THRESHOLD (default 20)
- arrived - started in one interval >= BACKLOG_THRESHOLD (default 15)
- every PERIODIC_EVERY seconds (default 1800, 0 = off)
- once at start (baseline)
- manually: touch /opt/jcloudnode/data/logs/thread-watch/CAPTURE_NOW

All settings are environment variables, e.g.
INTERVAL=15 NLWP_THRESHOLD=600 /opt/jcloudnode/data/logs/thread-watch.sh

After an hour of normal running, look at the usual nlwp in samples.log and set
NLWP_THRESHOLD to about twice that.

Other commands
/opt/jcloudnode/data/logs/thread-watch.sh capture               one dump set now
/opt/jcloudnode/data/logs/thread-watch.sh analyze td-*.txt.gz   re-summarise dumps

Disk safety: dumps are gzipped, at most MAX_SETS (40) sets are kept, and no
dump is taken when the volume has less than MIN_FREE_MB (500) free.

The process does not survive a pod restart; start it again afterwards.
