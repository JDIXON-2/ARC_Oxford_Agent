#!/bin/bash
#SBATCH --clusters=htc
#SBATCH --account={{ARC_ACCOUNT}}
#SBATCH --partition={{PARTITION}}
#SBATCH --job-name={{JOB_NAME}}
#SBATCH --time={{WALLTIME}}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task={{CPUS}}
#SBATCH --mem={{MEM}}
#SBATCH --gres=gpu:{{NGPU}}
#SBATCH --constraint='{{CONSTRAINT}}'
#SBATCH --output={{JOB_DIR}}/slurm-%j.out
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user={{MAIL_USER}}
#SBATCH --signal=B:USR1@300

set -uo pipefail

# Environment (does not rely on ~/.bashrc)
export DATA={{ARC_DATA}}
export HF_HOME=$DATA/hf_cache
export HF_TOKEN_PATH=$HOME/.cache/huggingface/token
export UV_CACHE_DIR=$DATA/.cache/uv
export WANDB_DIR={{JOB_DIR}}
export PYTHONUNBUFFERED=1
{{EXTRA_ENV}}

JOB_DIR={{JOB_DIR}}
# Compute nodes cannot reach ntfy.sh; notifications come from the watcher on the local machine

# Peak GPU memory sampler, read back into the ledger for future estimates
nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -l 30 > "$JOB_DIR/gpu_mem_mib.log" 2>/dev/null &
SAMPLER=$!

finish() {
    local rc=$1
    kill "$SAMPLER" 2>/dev/null
    local peak
    peak=$(sort -n "$JOB_DIR/gpu_mem_mib.log" 2>/dev/null | tail -1)
    echo "exit_code=$rc peak_gpu_mem_mib=${peak:-?}" | tee "$JOB_DIR/exit_status"
}
trap 'echo "[$(date -Is)] walltime ends in 5 min"' USR1

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
echo "host=$(hostname) gpu=$GPU_NAME start=$(date -Is)"
nvidia-smi

cd {{REMOTE_REPO}} || { finish 97; exit 97; }
echo "commit=$(git rev-parse HEAD)"

{{COMMAND}} &
CMD_PID=$!
wait "$CMD_PID"
RC=$?
# The USR1 trap interrupts `wait`; keep waiting while the command is still alive
while kill -0 "$CMD_PID" 2>/dev/null; do
    wait "$CMD_PID"
    RC=$?
done
finish "$RC"
exit "$RC"
