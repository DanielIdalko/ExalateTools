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
