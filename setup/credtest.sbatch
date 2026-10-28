#!/bin/bash
#SBATCH --clusters=htc
#SBATCH --account={{ARC_ACCOUNT}}
#SBATCH --partition=devel
#SBATCH --time=00:03:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --job-name=arc-setup-cred
#SBATCH --output={{ARC_DATA}}/arc_setup/credtest-%j.out

# Authenticated identity on HF and W&B, as a job sees it. Prints usernames only, never secrets.
printf 'HF: '
curl -s -m 15 -H "Authorization: Bearer $(cat "$HOME/.cache/huggingface/token" 2>/dev/null)" https://huggingface.co/api/whoami-v2 \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("name", d))'
printf 'WANDB: '
curl -s -m 15 --netrc -H 'Content-Type: application/json' -d '{"query":"{ viewer { username entity } }"}' https://api.wandb.ai/graphql \
    | python3 -c 'import sys,json; print(json.load(sys.stdin))'
