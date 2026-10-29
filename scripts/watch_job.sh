#!/bin/bash
# Watch an ARC job from morph: poll sacct every 5 min, and once the job is terminal,
# pull results back, append actual usage to the ledger, and send an ntfy notification.
#
# Usage: watch_job.sh <local_job_dir>
#   <local_job_dir>/job.env      sourced; defines JOB_ID JOB_NAME REMOTE_JOB_DIR NTFY_TOPIC LEDGER
#                                and the requested resources (REQ_*), REPO, COMMIT
#   <local_job_dir>/results.map  one "remote_path<TAB>local_path" per line (dirs end in /)

set -uo pipefail

LOCAL_JOB_DIR=$1
source "$LOCAL_JOB_DIR/job.env"
POLL_SECONDS=${POLL_SECONDS:-300}
TERMINAL='^(COMPLETED|FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|OUT_OF_ME\+|NODE_FAIL|PREEMPTED|BOOT_FAIL|DEADLINE)'

log() { echo "[$(date -Is)] $*" | tee -a "$LOCAL_JOB_DIR/watch.log"; }
notify() { curl -s -m 10 -H "Title: ARC $JOB_ID $JOB_NAME" -d "$1" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true; }

# Compute nodes cannot reach ntfy.sh, so every notification is sent from here
log "watching job $JOB_ID ($JOB_NAME)"
STARTED=0
WARNED=0
while true; do
    ROW=$(ssh -o BatchMode=yes -o ConnectTimeout=20 arc-htc \
        "sacct --clusters=htc -j $JOB_ID -X -n -P -o State,NodeList" 2>/dev/null | head -1)
    STATE=$(echo "$ROW" | cut -d'|' -f1 | awk '{print $1}')
    if [[ -z "$STATE" ]]; then
        log "sacct unreachable (login node reboot or network); retrying"
    elif [[ "$STATE" =~ $TERMINAL ]]; then
        break
    elif [[ "$STATE" == RUNNING ]]; then
        if [[ $STARTED == 0 ]]; then
            STARTED=1
            log "running on $(echo "$ROW" | cut -d'|' -f2)"
            notify "started on $(echo "$ROW" | cut -d'|' -f2), walltime $REQ_TIME"
        fi
        # %L is time left as [D-]HH:MM:SS or MM:SS; warn once when under 15 min
        LEFT=$(ssh -o BatchMode=yes -o ConnectTimeout=20 arc-htc "squeue --clusters=htc -h -j $JOB_ID -o %L" 2>/dev/null | tail -1)
        if [[ $WARNED == 0 && "$LEFT" =~ ^([0-9]+:)?[0-9]+$ ]] && [[ ! "$LEFT" =~ - ]]; then
            MINS=$(echo "$LEFT" | awk -F: '{ if (NF==3) print $1*60+$2; else print $1 }')
            if (( MINS < 15 )); then
                WARNED=1
                notify "walltime nearly up: $LEFT left of $REQ_TIME"
            fi
        fi
    fi
    sleep "$POLL_SECONDS"
done
log "terminal state: $STATE"

# Bulk transfer goes through the gateway when its key works, otherwise the login node
XFER=arc-htc
ssh -o BatchMode=yes -o ConnectTimeout=20 arc-gw true 2>/dev/null && XFER=arc-gw

PULL_OK=1
while IFS=$'\t' read -r REMOTE LOCAL; do
    [[ -z "$REMOTE" ]] && continue
    mkdir -p "$(dirname "$LOCAL")"
    log "pull $XFER:$REMOTE -> $LOCAL"
    rsync -a --partial "$XFER:$REMOTE" "$LOCAL" >> "$LOCAL_JOB_DIR/watch.log" 2>&1 || PULL_OK=0
done < "$LOCAL_JOB_DIR/results.map"
rsync -a "$XFER:$REMOTE_JOB_DIR/" "$LOCAL_JOB_DIR/remote/" >> "$LOCAL_JOB_DIR/watch.log" 2>&1 || PULL_OK=0

# Actual usage, for future estimates. Re-read job.env and take constraint/QoS from sacct,
# since a pending job may have been changed with scontrol after the watcher started.
source "$LOCAL_JOB_DIR/job.env"
ALLOC=$(ssh -o BatchMode=yes arc-htc "sacct --clusters=htc -j $JOB_ID -X -n -P -o Constraints,QOS --delimiter=@" 2>/dev/null | head -1)
# Constraints itself contains '|', hence the '@' delimiter
REQ_CONSTRAINT=${ALLOC%%@*}
QOS=${ALLOC##*@}
SACCT=$(ssh -o BatchMode=yes arc-htc "sacct --clusters=htc -j $JOB_ID -n -P -o JobID,Elapsed,MaxRSS,NodeList,ExitCode" 2>/dev/null)
ELAPSED=$(echo "$SACCT" | awk -F'|' -v j="$JOB_ID" '$1==j {print $2}')
NODE=$(echo "$SACCT" | awk -F'|' -v j="$JOB_ID" '$1==j {print $4}')
MAXRSS=$(echo "$SACCT" | awk -F'|' -v j="$JOB_ID.batch" '$1==j {print $3}')
PEAK_GPU=$(grep -o 'peak_gpu_mem_mib=[0-9?]*' "$LOCAL_JOB_DIR/remote/exit_status" 2>/dev/null | cut -d= -f2)
GPU_NAME=$(grep -o 'gpu=.* start=' "$LOCAL_JOB_DIR/remote/slurm-$JOB_ID.out" 2>/dev/null | head -1 | sed 's/^gpu=//; s/ start=$//')

printf '{"job_id":"%s","name":"%s","repo":"%s","commit":"%s","state":"%s","partition":"%s","constraint":"%s","qos":"%s","req_time":"%s","req_mem":"%s","req_cpus":"%s","req_gpus":"%s","elapsed":"%s","max_rss":"%s","peak_gpu_mem_mib":"%s","gpu":"%s","node":"%s","finished":"%s"}\n' \
    "$JOB_ID" "$JOB_NAME" "$REPO" "$COMMIT" "$STATE" "$REQ_PARTITION" "$REQ_CONSTRAINT" "${QOS:-}" "$REQ_TIME" "$REQ_MEM" "$REQ_CPUS" "$REQ_GPUS" \
    "$ELAPSED" "$MAXRSS" "${PEAK_GPU:-}" "${GPU_NAME:-}" "$NODE" "$(date -Is)" >> "$LEDGER"

MSG="$STATE after $ELAPSED of $REQ_TIME on ${GPU_NAME:-?}; peak GPU ${PEAK_GPU:-?} MiB, MaxRSS ${MAXRSS:-?} (req $REQ_MEM)"
[[ $PULL_OK == 1 ]] && MSG="$MSG; results pulled" || MSG="$MSG; RESULT PULL FAILED, see $LOCAL_JOB_DIR/watch.log"
log "$MSG"
notify "$MSG"
