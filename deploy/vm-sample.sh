#!/usr/bin/env bash
# deploy/vm-sample.sh — sample memory/CPU on the VM every second for N seconds; print peaks.
#   bash deploy/vm-sample.sh 60 > /tmp/peak.txt
N="${1:-60}"; LOG=/tmp/vm-sample.log; : > "$LOG"
for i in $(seq 1 "$N"); do
  read -r _ total used free shared buff avail < <(free -m | awk '/^Mem/')
  read -r _ stotal sused _ < <(free -m | awk '/^Swap/')
  load=$(cut -d' ' -f1 /proc/loadavg)
  rss=$(ps -o rss= -C julia | head -1); cpu=$(ps -o pcpu= -C julia | head -1)
  echo "$(date +%T) used=$used avail=$avail swap=$sused load=$load rss_kb=${rss:-0} cpu=${cpu:-0}" >> "$LOG"
  sleep 1
done
awk '{for(i=2;i<=NF;i++){split($i,a,"="); v=a[2]+0; if(a[1]=="used"&&v>pu)pu=v; if(a[1]=="avail"&&(ma==""||v<ma))ma=v; if(a[1]=="swap"&&v>ps)ps=v; if(a[1]=="load"&&v>pl)pl=v; if(a[1]=="rss_kb"&&v>pr)pr=v; if(a[1]=="cpu"&&v>pc)pc=v}}
     END{printf "samples=%d peak_used_MB=%d min_avail_MB=%d peak_swap_MB=%d peak_load1=%.2f peak_julia_rss_MB=%d peak_julia_cpu=%.1f%%\n", NR, pu, ma, ps, pl, pr/1024, pc}' "$LOG"
