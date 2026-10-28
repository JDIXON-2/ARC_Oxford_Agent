# ARC rules and facts (verified 2026-10-28)

Sources: [ARC user guide](https://arc-user-guide.readthedocs.io/en/latest/index.html) — [job scheduling](https://arc-user-guide.readthedocs.io/en/latest/job-scheduling.html), [script basics](https://arc-user-guide.readthedocs.io/en/latest/arc-script-basics.html), [copying data](https://arc-user-guide.readthedocs.io/en/latest/arc-copying-data.html), [storage](https://arc-user-guide.readthedocs.io/en/latest/arc-storage.html), [systems](https://arc-user-guide.readthedocs.io/en/latest/arc-systems.html), [host keys](https://arc-user-guide.readthedocs.io/en/latest/arc-host-keys.html). Re-check the docs if anything here conflicts with what the cluster reports.

## Account
The user's values (username, project, `$DATA`, email, ntfy topic) are in [../config.env](../config.env).

| Item | Value |
|---|---|
| `$DATA` | `/data/<project>/<user>`, project quota shared with group members (`myquota`) |
| `$HOME` | `/home/<user>`, about 15 to 20 GB, private (`drwx------`). Secrets live here |
| SSH aliases (local `~/.ssh/config`) | `arc-htc` = htc-login (submit, git, light commands). `arc-gw` = gateway (bulk data transfer, sees `$DATA`, separate home) |
| Credentials on ARC | HF token `~/.cache/huggingface/token` (via `HF_TOKEN_PATH`). W&B `~/.netrc` entry for `api.wandb.ai` |
| Compute-node internet | Yes, direct (HF, W&B, GitHub, PyPI reachable; no proxy). **ntfy.sh is blocked**, so notify from the local machine. Checked 2026-10-28 |
| `mybalance` | Not available on htc-login |

`$DATA` is readable by everyone in the project group, so never put tokens or keys under it.

## Hard rules
1. **Login nodes**: job submission, `git`, `rsync` endpoints, `squeue`/`sacct` only. No compute, no `uv sync`/conda builds, no Python runs (1 h CPU limit per process; banner forbids builds). Builds go through `srun -p interactive`.
2. **GPUs exist only on `htc`**: always `--clusters=htc`.
3. **Always set `--partition` explicitly.** On htc the default is `long` (lower priority), not `short`.
4. **No time extensions** in short/medium — walltime must be safe on the first try.
5. **`devel`** (10 min max) is only for short test jobs. **`interactive`** (24 h max) is for builds/debugging.
6. **Always pass `--account=<ARC_ACCOUNT>`** on `sbatch`/`srun`, and use `ARC_DATA` from config rather than the shell's `$DATA`. Users in several projects otherwise charge, and write to, the wrong one.
7. **No `--exclusive`**. Request only cores/memory/GPUs actually used; nodes are shared.
8. **No `--qos=priority`** unless the user explicitly asks (costs priority credit).
   - **`--qos=math-lasr`** is the group's own priority QoS for H100s: priority 5000, at most 4 GPUs at once across the whole group, `PartitionTimeLimit`. It's the **preferred default for GPU jobs** whenever group slots are free; see SKILL.md Step 5. The account can use the `basic`, `standard` (default), `priority` and `math-lasr` QoS.
9. Transfer data into `$DATA`, never into `$HOME` on the gateway (gateway has a separate, tiny home).
10. `$SCRATCH` / `$TMPDIR` are deleted at job exit; anything worth keeping must be written to `$DATA` before the job ends.
11. Scripts must start with `#!/bin/bash`, `#SBATCH` lines at column 0, Unix line endings.
12. `--output` directory must already exist, or Slurm fails without a log.
13. Poll `squeue`/`sacct` no more often than every 5 min.
14. Login nodes reboot **Tuesdays 09:15–10:00** — tolerate SSH failures in that window.

## Partitions (htc)
| Partition | Default | Max | GPUs available (sinfo, 2026-10-28) |
|---|---|---|---|
| `short` | 1 h | 12 h | V100-32GB, Titan RTX, RTX8000, A6000, L40S, A100-40GB, H100 (80/94 GB) |
| `medium` | 12 h | 48 h | RTX8000, L40S, A100-40GB, H100-80GB |
| `long` | 24 h | 30 d | RTX8000, L40S, A100-40GB, H100-80GB (lower priority) |
| `devel` | — | 10 min | RTX8000 |
| `interactive` | — | 24 h | RTX8000 |

Default memory is 8000 MB per CPU; default 1 CPU.

## GPU request syntax
```
#SBATCH --gres=gpu:1
#SBATCH --constraint='gpu_sku:L40S|gpu_sku:A100'
```
`gpu_sku` feature values as reported by sinfo: `V100`, `RTX` (Titan RTX), `RTX8000`, `RTX-A6000`, `L40S`, `A100`, `H100`. Other keys: `gpu_mem:<N>GB`, `gpu_cc:<x.y>`, `gpu_gen:{Volta,Turing,Ampere,Lovelace,Hopper}`. Re-query live with:
```
sinfo --clusters=htc -h -o "%P|%G|%f" | sort -u
```
