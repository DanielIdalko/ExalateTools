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
      ps -o pid,ppid,%cpu,%mem,rss,vsz,nlwp,etime,cmd -p "$JAVA_PID"
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
