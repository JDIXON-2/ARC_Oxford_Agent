#!/bin/bash
#SBATCH --clusters=htc
#SBATCH --account={{ARC_ACCOUNT}}
#SBATCH --partition=devel
#SBATCH --time=00:03:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --job-name=arc-setup-net
#SBATCH --output={{ARC_DATA}}/arc_setup/nettest-%j.out

# Compute-node outbound access. Any HTTP code (even 3xx/4xx) means reachable; 000 means blocked.
hostname
for u in https://huggingface.co/api/models/gpt2 https://api.wandb.ai https://github.com https://pypi.org/simple/ https://ntfy.sh/v1/health; do
    printf '%s -> ' "$u"
    curl -s -o /dev/null -m 15 -w '%{http_code}\n' "$u" || echo FAIL
done
env | grep -i -E '^(https?|no)_proxy' || echo "no proxy vars"
