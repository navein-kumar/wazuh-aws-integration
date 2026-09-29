#!/bin/bash
# aws-loop: runs every line of aws-jobs.conf through the Wazuh AWS module, one after another, sleeps
# WAIT seconds, repeats. Three files only: this script, aws-jobs.conf, aws-loop-rules.xml.
#
# Instances: one install is one service with its own folder, config, state and logs. Install as many as
#   needed, each with a name; they run in parallel, so a large number of buckets can be split across
#   several services instead of one long round.
#     default        /opt/aws-loop/            service aws-loop         logs /var/log/aws-loop/aws-loop.log|.json
#     NAME           /opt/aws-loop/NAME/       service aws-loop-NAME    logs /var/log/aws-loop/aws-loop-NAME.log|.json
#   NAME: letters, digits, - and _ only. Put each bucket or service line in exactly one instance.
# Isolation: every config line runs in its own environment under <instance>/env/<job>/, a tree of
#   symlinks to /var/ossec with private copies of utils.py, aws-s3.py and the state databases. Jobs never
#   share a SQLite file, so they never lock each other and any number can run at the same time.
# Async:     a job still running after SOFT seconds is detached (keeps running in the background) and the
#   loop moves on; when it finishes, the next round records its result and it rejoins.
# Health:    one health line per round: job counts, detached jobs, manager socket, analysisd drops, disk.
# Logs:      aws-loop[-NAME].log   full module output (debug 2)
#            aws-loop[-NAME].json  one line per job ("kind":"job") + one per round ("kind":"health"), field "instance"
#            job result: ok | empty | fail | denied (permission or credential) | locked | stalled (no output for STALL s) | killed | detached | deferred
#
#   bash aws-loop.sh [NAME]      run in the foreground (manual test, Ctrl-C to stop)
#   bash aws-loop.sh -i [NAME]   install (existing config kept), enable at boot and start the service
#   bash aws-loop.sh -s [NAME]   status: service state, running job, last results, last health line
#   bash aws-loop.sh -u [NAME]   remove the service (files, config and logs are kept)
#   bash aws-loop.sh -l          list installed instances
#   systemctl status|restart|stop aws-loop[-NAME]
BASE=/opt/aws-loop
LOGDIR=/var/log/aws-loop
WAZUH=/var/ossec
PYTHON=$WAZUH/framework/python/bin/python3
WAIT=120         # seconds between rounds
SOFT=300         # seconds before a running job is detached and the loop moves on
MAX_RUN=21600    # hard kill after 6 h, even if still producing output
STALL=1800       # kill a job whose output has not grown for 30 min: it is stuck, not working
DEBUG=2

ACTION=""; NAME=""
case "${1:-}" in
  -i|install|-s|status|-u|uninstall) ACTION="$1"; NAME="${2:-}" ;;
  -l|list) for u in /etc/systemd/system/aws-loop*.service; do [ -e "$u" ] || { echo "no instances installed"; break; }; u=$(basename "$u" .service); echo "$u  $(systemctl is-enabled "$u" 2>/dev/null)  $(systemctl is-active "$u" 2>/dev/null)  $(sed -n 's/^ExecStart=\(.*\)\/aws-loop.sh.*/\1/p' "/etc/systemd/system/$u.service")"; done; exit 0 ;;
  -*|-h|--help) sed -n '21,26p' "$0"; exit 2 ;;
  *) NAME="${1:-}" ;;
esac
if [ -n "$NAME" ]; then
  echo "$NAME" | grep -qE '^[A-Za-z0-9_-]+$' || { echo "bad instance name '$NAME': letters, digits, - and _ only"; exit 2; }
  DEST=$BASE/$NAME; SERVICE=aws-loop-$NAME; INSTANCE=$NAME; LOG=$LOGDIR/aws-loop-$NAME.log; JSON=$LOGDIR/aws-loop-$NAME.json
else
  DEST=$BASE; SERVICE=aws-loop; INSTANCE=default; LOG=$LOGDIR/aws-loop.log; JSON=$LOGDIR/aws-loop.json
fi
CONF=$DEST/aws-jobs.conf
STATE=$DEST/state
UNIT=/etc/systemd/system/$SERVICE.service

case "$ACTION" in
  -i|install)
    [ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
    src="$(cd "$(dirname "$0")" && pwd)"
    mkdir -p "$DEST" "$STATE" "$LOGDIR"
    [ "$(readlink -f "$0")" = "$DEST/aws-loop.sh" ] || { cp "$0" "$DEST/aws-loop.sh" && chmod 750 "$DEST/aws-loop.sh"; }
    if [ -f "$CONF" ]; then echo "config: keeping existing $CONF"
    elif [ -f "$src/aws-jobs.conf" ] && [ "$src" != "$BASE" ]; then cp "$src/aws-jobs.conf" "$CONF" && chmod 640 "$CONF" && echo "config: installed $CONF, edit the lines"
    elif [ -n "$NAME" ]; then printf '# %s. One line per service. Remove # to enable. Replace names with real ones.\n# Order does not matter: every line runs in its own environment with its own state file.\n\n# CloudTrail\n#--bucket cloudtrail-bucket --type cloudtrail --regions ap-south-1 --only_logs_after 2026-SEP-18\n' "$CONF" > "$CONF" && chmod 640 "$CONF" && echo "config: created empty $CONF, add the lines for this instance"
    else echo "config: $CONF missing and no aws-jobs.conf next to the script"; exit 1; fi
    for p in $(pgrep -f "aws-loop\.sh${NAME:+ $NAME}$"); do [ "$p" != "$$" ] && [ "$p" != "$PPID" ] && kill "$p" 2>/dev/null; done
    cat > "$UNIT" <<EOF
[Unit]
Description=Wazuh AWS module loop runner ($INSTANCE)
After=network-online.target wazuh-manager.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DEST/aws-loop.sh $NAME
Restart=always
RestartSec=30
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now "$SERVICE" >/dev/null 2>&1 && systemctl restart "$SERVICE"
    sleep 1; systemctl is-active "$SERVICE" >/dev/null && echo "installed: $DEST/aws-loop.sh, service $SERVICE running and enabled at boot, logs $LOG and $JSON"
    echo "rules: add the <localfile> block and the rules from aws-loop-rules.xml once, then restart wazuh-manager"
    exit 0 ;;
  -s|status)
    systemctl status "$SERVICE" --no-pager 2>/dev/null | head -5; echo
    echo "running job: $(pgrep -af "$DEST/env/" | grep -o -- "--bucket [^ ]*\|--service [^ ]*\|--subscriber [^ ]*" | head -1)"
    echo "last results:"; grep '"kind":"job"' "$JSON" 2>/dev/null | tail -n 8 | sed -n 's/.*"type":"\([^"]*\)","name":"\([^"]*\)","result":"\([^"]*\)".*"files_found":\([0-9]*\).*"time":"\([^"]*\)".*/  \5  \1 \2  \3  files=\4/p'
    echo "last health:"; grep '"kind":"health"' "$JSON" 2>/dev/null | tail -n 1 | sed 's/[{}"]//g; s/,/  /g; s/app:aws-loop  instance:[^ ]*  kind:health  //'
    exit 0 ;;
  -u|uninstall)
    systemctl disable --now "$SERVICE" 2>/dev/null; rm -f "$UNIT"; systemctl daemon-reload
    echo "service $SERVICE removed. Kept: $DEST, $LOG, $JSON"; exit 0 ;;
esac

[ -f "$CONF" ] || { echo "no config: $CONF"; exit 1; }
mkdir -p "$STATE" "$LOGDIR"
exec >> "$LOG" 2>&1

ts()      { date -u +%FT%TZ; }
clean_line() { # config line -> one space between arguments: drops CR, tabs, repeated, leading and trailing spaces, spaces around commas, trailing # comments
  printf '%s' "$1" | tr -d '\r' | tr '\t' ' ' | sed 's/ *#.*$//; s/  */ /g; s/^ //; s/ $//; s/ *, */,/g'; }
type_of() { echo "$1" | sed -n 's/.*--type \([^ ]*\).*/\1/p; s/.*--service \([^ ]*\).*/\1/p; s/.*--subscriber \([^ ]*\).*/\1/p' | head -1; }
name_of() { echo "$1" | sed -n 's/.*--bucket \([^ ]*\).*/\1/p; s/.*--queue \([^ ]*\).*/\1/p; s/.*--aws_log_groups \([^ ]*\).*/\1/p' | head -1; }
env_name() { printf '%s-%s-%s' "$(type_of "$1")" "$(name_of "$1" | tr -c 'A-Za-z0-9._\n-' '_')" "$(echo "$1" | md5sum | cut -c1-6)"; }

make_env() { # make_env ARGS -> prints the env dir; built on first use, seeded with the current state files
  local e="$DEST/env/$(env_name "$1")" x b
  if [ ! -f "$e/wodles/utils.py" ]; then
    mkdir -p "$e/wodles/aws"
    for x in "$WAZUH"/*; do b=$(basename "$x"); [ "$b" = wodles ] || ln -sfn "$x" "$e/$b"; done
    for x in "$WAZUH"/wodles/aws/*; do b=$(basename "$x"); case "$b" in *.db|aws-s3|aws-s3.py|aws-s3.orig|aws-s3.real|__pycache__|.lock-*) ;; *) ln -sfn "$x" "$e/wodles/aws/$b";; esac; done
    cp "$WAZUH"/wodles/aws/*.db "$e/wodles/aws/" 2>/dev/null
    echo "$(ts) ENV   created $e" >&2
  fi
  # real copies, not links: Python resolves a symlinked script to its real directory, which would make the
  # module import the real utils.py and write the shared /var/ossec database again. Refreshed after upgrades.
  cp -u "$WAZUH/wodles/utils.py" "$e/wodles/utils.py"
  cp -u "$WAZUH/wodles/aws/aws-s3.py" "$e/wodles/aws/aws-s3.py"
  echo "$e"
}

emit() { # emit ARGS RESULT RC SECS OUTFILE
  local args="$1" result="$2" rc="$3" secs="$4" out="$5" files=0 err=""
  [ -f "$out" ] && { files=$(grep -c "Found new log" "$out"); err=$(grep -E "ERROR|Error|error occurred|Traceback" "$out" | tail -1 | sed 's/[\\"]//g' | cut -c1-300); }
  printf '{"app":"aws-loop","instance":"%s","kind":"job","round":%s,"round_start":"%s","type":"%s","name":"%s","result":"%s","exit":%s,"seconds":%s,"files_found":%s,"error":"%s","args":"%s","time":"%s"}\n' \
    "$INSTANCE" "$round" "$round_start" "$(type_of "$args")" "$(name_of "$args")" "$result" "$rc" "$secs" "$files" "$err" "$(echo "$args" | sed 's/[\\"]//g')" "$(ts)" >> "$JSON"
  echo "$(ts) END   result=$result exit=$rc seconds=$secs files=$files $args"
  eval "n_$result=\$((n_$result+1))"
}

finalize() { # finalize ARGS START OUTFILE RCFILE
  local args="$1" start="$2" out="$3" rcf="$4" rc secs result
  rc=$(cat "$rcf" 2>/dev/null || echo 1); secs=$(( $(date +%s) - start ))
  cat "$out"
  if [ -f "$out.stalled" ]; then result=stalled; echo "ERROR: killed by aws-loop: no output for ${STALL}s" >> "$out"; rm -f "$out.stalled"
  elif grep -q "database is locked" "$out"; then result=locked
  elif grep -qE "AccessDenied|not authorized|InvalidAccessKeyId|InvalidClientTokenId|Unable to locate credentials|ExpiredToken|SignatureDoesNotMatch" "$out"; then result=denied
  elif [ "$rc" -eq 124 ]; then result=killed
  elif [ "$rc" -eq 14 ]; then result=empty
  elif [ "$rc" -ne 0 ]; then result=fail
  else result=ok; fi
  emit "$args" "$result" "$rc" "$secs" "$out"
  rm -f "$out" "$rcf"
}

collect_detached() { # records finished detached jobs; returns 0 if the job named in $1 is still running detached
  local f pid args start out rcf busy=1
  for f in "$STATE"/detached.*; do
    [ -e "$f" ] || continue
    { read -r pid; read -r args; read -r start; read -r out; read -r rcf; } < "$f"
    if kill -0 "$pid" 2>/dev/null; then
      [ "$args" = "$1" ] && busy=0
      if [ $(( $(date +%s) - $(stat -c %Y "$out") )) -ge "$STALL" ]; then
        echo "$(ts) STALL no output for ${STALL}s, killing session $pid: $args"; touch "$out.stalled"; pkill -TERM -s "$pid" 2>/dev/null; sleep 2; pkill -KILL -s "$pid" 2>/dev/null; fi
    else echo "$(ts) JOIN  detached job finished: $args"; finalize "$args" "$start" "$out" "$rcf"; rm -f "$f"; fi
  done
  return $busy
}

run_job() { # run_job ARGS
  local args="$1" e start out rcf bg
  if collect_detached "$args"; then echo "$(ts) DEFER still running detached: $args"; emit "$args" deferred 0 0 ""; return; fi
  e=$(make_env "$args")
  out=$(mktemp "$STATE/out.XXXXXX"); rcf="$out.rc"; start=$(date +%s); export OUT="$out" RCF="$rcf"
  echo "$(ts) START $args"
  setsid bash -c 'timeout "$0" "$1" "$2" "${@:4}" --debug "$3" < /dev/null > "$OUT" 2>&1; echo $? > "$RCF"' "$MAX_RUN" "$PYTHON" "$e/wodles/aws/aws-s3.py" "$DEBUG" $args &
  bg=$!
  while kill -0 "$bg" 2>/dev/null; do
    if [ $(( $(date +%s) - start )) -ge "$SOFT" ]; then
      printf '%s\n%s\n%s\n%s\n%s\n' "$bg" "$args" "$start" "$out" "$rcf" > "$STATE/detached.$bg"
      echo "$(ts) DETACH running longer than ${SOFT}s, continuing in background (pid $bg): $args"
      emit "$args" detached 0 $(( $(date +%s) - start )) ""; return
    fi
    sleep 2
  done
  finalize "$args" "$start" "$out" "$rcf"
}

health() { # one line per round
  local det=0 oldest=0 f pid start age sock=ok dropped=0 queue=0 disk_log disk_opt st="$WAZUH/var/run/wazuh-analysisd.state"
  for f in "$STATE"/detached.*; do [ -e "$f" ] || continue; { read -r pid; read -r _; read -r start; } < "$f"
    kill -0 "$pid" 2>/dev/null && { det=$((det+1)); age=$(( $(date +%s) - start )); [ "$age" -gt "$oldest" ] && oldest=$age; }; done
  [ -S "$WAZUH/queue/sockets/queue" ] || sock=missing
  [ -f "$st" ] && { dropped=$(sed -n "s/^events_dropped='\([0-9]*\)'.*/\1/p" "$st"); queue=$(sed -n "s/^event_queue_usage='\([0-9.]*\)'.*/\1/p" "$st"); }
  local last delta=0; last=$(cat "$STATE/dropped_last" 2>/dev/null || echo "${dropped:-0}"); [ "${dropped:-0}" -ge "$last" ] && delta=$(( ${dropped:-0} - last )); echo "${dropped:-0}" > "$STATE/dropped_last"
  disk_log=$(df -P "$LOGDIR" | awk 'NR==2{print 100-$5}'); disk_opt=$(df -P "$DEST" | awk 'NR==2{print 100-$5}')
  printf '{"app":"aws-loop","instance":"%s","kind":"health","round":%s,"jobs_ok":%s,"jobs_empty":%s,"jobs_fail":%s,"jobs_denied":%s,"jobs_locked":%s,"jobs_killed":%s,"jobs_detached":%s,"jobs_deferred":%s,"detached_running":%s,"oldest_detached_s":%s,"manager_socket":"%s","analysisd_dropped_total":%s,"analysisd_dropped_delta":%s,"analysisd_queue_pct":%s,"disk_free_log_pct":%s,"disk_free_opt_pct":%s,"time":"%s"}\n' \
    "$INSTANCE" "$round" "$n_ok" "$n_empty" "$n_fail" "$n_denied" "$n_locked" "$n_killed" "$n_detached" "$n_deferred" "$det" "$oldest" "$sock" "${dropped:-0}" "$delta" "${queue:-0}" "$disk_log" "$disk_opt" "$(ts)" >> "$JSON"
  echo "$(ts) HEALTH ok=$n_ok empty=$n_empty fail=$n_fail denied=$n_denied locked=$n_locked killed=$n_killed detached=$n_detached deferred=$n_deferred running_detached=$det socket=$sock dropped_delta=$delta disk_log=${disk_log}% disk_opt=${disk_opt}%"
}

while true; do
  round=$(( $(cat "$STATE/round" 2>/dev/null || echo 0) + 1 )); echo "$round" > "$STATE/round"
  round_start=$(ts)
  n_ok=0 n_empty=0 n_fail=0 n_denied=0 n_locked=0 n_killed=0 n_detached=0 n_deferred=0
  echo "$round_start ===== round $round start ($INSTANCE) ====="
  collect_detached "" || true
  while read -r args; do args=$(clean_line "$args"); [ -n "$args" ] && run_job "$args"; done < <(grep -vE '^\s*(#|$)' "$CONF")
  health
  echo "$(ts) ===== round $round end, sleeping ${WAIT}s ====="
  sleep "$WAIT"
done
