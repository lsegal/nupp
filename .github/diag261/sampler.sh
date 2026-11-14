#!/usr/bin/env bash
# Every 30 s: free memory, swap, and the largest processes with their command.
while true; do
  if [ "$RUNNER_OS" = Linux ]; then
    echo "[mem] $(date +%T) $(free -m | awk 'NR==2{print "used="$3"M avail="$7"M"} NR==3{print "swap="$3"M"}' | paste -sd' ' -)"
    ps -eo pid,ppid,rss,etime,args --sort=-rss | sed -n '2,7p' | awk '{printf "[ps] %s %s %dM %s", $1, $2, $3/1024, $4; for (i=5;i<=NF;i++) printf " %s", $i; printf "\n"}' | cut -c1-220
  else
    echo "[mem] $(date +%T) $(sysctl -n vm.swapusage) free=$(vm_stat | awk '/Pages free/{gsub(/\./,"",$3); print $3*16/1024"M"}') load=$(sysctl -n vm.loadavg)"
    ps -axo pid,ppid,rss,etime,command -m | sed -n '2,7p' | awk '{printf "[ps] %s %s %dM %s", $1, $2, $3/1024, $4; for (i=5;i<=NF;i++) printf " %s", $i; printf "\n"}' | cut -c1-220
  fi
  sleep 30
done
