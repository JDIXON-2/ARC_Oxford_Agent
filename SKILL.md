---
name: arc-submit
description: Use when asked to run, submit, launch, or offload an experiment, training run, evaluation, or sweep to ARC / the Oxford ARC cluster / HTC / Slurm instead of running it on morph. Syncs the experiment's code (git, including sibling path-dependency repos) and input data to the user's ARC $DATA area, builds the uv env on an interactive node, sizes the smallest sufficient GPU, memory, and walltime from previous runs plus published GPU specs, writes and (after user confirmation) submits an sbatch script, and starts a tmux watcher on morph that pulls results back and sends ntfy and email notifications. Follows ARC cluster rules throughout. Also use it to set up ARC access for a new user or a new machine (SSH keys, host aliases, HF/W&B credentials, connectivity tests), via setup/SETUP.md. For runs on morph's own GPUs, use run-experiment or run-experiment-series.
---

# Submit an experiment to ARC

## Step 0: Load config (or run setup)
Source [config.env](config.env). It holds `ARC_USER ARC_PROJECT ARC_ACCOUNT ARC_DATA MAIL_USER NTFY_TOPIC LOCAL_PROJECTS`. Below, `$DATA` means `ARC_DATA` and `<projects>` means `LOCAL_PROJECTS`.

**Multiple projects:** the user can belong to several ARC project accounts. Every `sbatch` and `srun` must pass `--account=<ARC_ACCOUNT>`; the job template sets it as an `#SBATCH` line. Never rely on the login shell's `$DATA` or default account. They may point at a different project, so always spell out `ARC_DATA` in commands sent to ARC.

If `config.env` is missing, `SETUP_VERIFIED` is empty, or `ssh -o BatchMode=yes arc-htc true` fails, follow [setup/SETUP.md](setup/SETUP.md) before anything else. Also follow it when the user asks to set up ARC.

Read [reference/arc_rules.md](reference/arc_rules.md) before running any command on ARC. Its "Hard rules" section applies throughout. In particular, nothing heavier than `git`, `rsync`, `sbatch`, `squeue` or `sacct` runs on a login node.

Paths:

| | morph | ARC |
|---|---|---|
| repos | `<projects>/<repo>` | `$DATA/code/<repo>` (same layout, so `../<repo>` path deps resolve) |
| job records | `<projects>/.arc_jobs/<repo>/<job_name>/` | `$DATA/arc_jobs/<repo>/<job_name>/` |
| usage ledger | `<projects>/.arc_jobs/ledger.jsonl` | — |

`<job_name>` = `<experiment-slug>-<YYYYMMDD-HHMM>`. `$DATA` is spelled out as `ARC_DATA` in anything sent to ARC.

## Step 1: Identify the experiment and everything it needs
1. Discover the entry point and hyperparameters as `run-experiment` does: CLI flags, configs and overrides, env vars, and hardcoded constants. Do not hardcode a GPU index. On ARC the job only sees the GPU it was given.
2. **Code closure:** the repo plus every `[tool.uv.sources]` entry with `path = "../<x>"`, checked recursively in each sibling's `pyproject.toml`.
3. **Data closure:** every input path the run reads that is not tracked by git, such as `data/dataset/...`, cached activations and checkpoints. Use paths relative to the repo root. HF Hub models and datasets do not need copying, because compute nodes download them into `$DATA/hf_cache`.
4. **Results paths:** where the run writes its outputs, relative to the repo root. Read the save code to find them; don't infer them from the run name. If each run writes a timestamped or config-named subdirectory, map the stable parent directory: rsync only copies new files, so this stays cheap.
5. **Multi-GPU:** request N>1 only if the code really uses N devices (DDP, `device_map` across GPUs).
6. **Dtype:** check whether the run uses `torch.bfloat16`. This decides whether the cc 7.x GPUs (V100, RTX8000, Titan RTX) can be used.

If the entry point, data or results paths are unclear, say so and ask. Do not guess.

## Step 2: Sync code (git only)
For each repo in the code closure:
1. On morph, `git status --porcelain --untracked-files=no` must be empty. If not, **stop**, list the changes, and ask the user to commit. Never commit or push on their behalf. Also warn about untracked `*.py` files the run imports.
2. `git branch -r --contains HEAD` must be non-empty, meaning HEAD is pushed. If not, ask the user to push.
3. On ARC, through `ssh arc-htc`:
   - If `$DATA/code/<repo>` is missing, run `git clone <origin-url>`.
   - Then run `git fetch --all -q && git stash -u -q; git checkout -q --detach <sha>`.
   - Stashing is fine: local edits on the ARC copies are disposable.
4. Check that `git rev-parse HEAD` on ARC equals the local SHA for every repo.

## Step 3: Sync data
- Bulk data goes through **`arc-gw`** (the gateway). Check it first with `ssh -o BatchMode=yes arc-gw true`.
- If key auth to `arc-gw` fails, the gateway key is missing. Ask the user to run `! ssh-copy-id -i ~/.ssh/id_ed25519.pub <ARC_USER>@gateway.arc.ox.ac.uk` (see [setup/SETUP.md](setup/SETUP.md) Step 4).
- Until that's done, use `arc-htc` only for transfers under about 1 GB. The login node's 1 h CPU limit makes it unsuitable for large ones.
- `rsync -a --partial --info=progress2 <projects>/<repo>/<rel>/ arc-gw:$DATA/code/<repo>/<rel>/` (with `$DATA` spelled out). rsync copies only missing or changed files, so re-runs are cheap.
- Before copying more than 50 GB, tell the user the size and confirm.
- Never write into `$HOME` on the gateway.

## Step 4: Ensure the environment (interactive node)
- **Check morph's env for drift first:** run `uv sync --frozen --dry-run` in the local repo. If it would uninstall anything, those packages were installed by hand and aren't in `uv.lock`, so the ARC env won't have them. Tell the user and propose `uv add <pkg>==<local version>` plus a commit, rather than patching ARC by hand. A later `uv sync` would delete a hand-installed package again.
- The env is the repo's uv `.venv` on ARC. Rebuild it only when `uv.lock` or any `pyproject.toml` in the code closure differs from the hash recorded at `$DATA/code/<repo>/.venv/.arc_lock_sha`. The hash is `sha256sum uv.lock */pyproject.toml` across the closure.
- Build command, run from morph:
  ```
  ssh arc-htc 'srun --clusters=htc --account=<ARC_ACCOUNT> -p interactive --cpus-per-task=4 --mem=16G --time=00:45:00 bash -lc "cd <ARC_DATA>/code/<repo> && UV_CACHE_DIR=<ARC_DATA>/.cache/uv uv sync --frozen && <write hash>"'
  ```
- **First time a repo runs on ARC, or after a rebuild:** run a smoke job on `devel` (`--account=<ARC_ACCOUNT> --time=00:10:00 --gres=gpu:1 --cpus-per-task=2 --mem=8G`). A cold `import torch` from a fresh venv on `$DATA` took 87 s, and 5 min wasn't enough. Use `python -u` with timestamped prints so a timeout still shows how far it got.
  - It runs `uv run --frozen --no-sync python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"` and imports the experiment's main module.
  - Fix any failure before Step 6.
  - Devel only offers the RTX8000, so a bf16 kernel error there is expected and is not a failure.

## Step 5: Estimate resources (conservatively, from evidence)
Use [reference/gpu_specs.md](reference/gpu_specs.md). Do **not** run a local profiling job.

**Evidence, in priority order.** Cite the source of every number.
1. `ledger.jsonl`: earlier ARC runs of the same experiment with comparable config. Use the actual `elapsed`, `peak_gpu_mem_mib` and `max_rss` directly, since no scaling is needed.
2. Earlier local runs on morph:
   - W&B run `_runtime` plus the peak `system.gpu.*.memoryAllocatedBytes` (query with the `wandb` API; local `~/.netrc` is set up).
   - Or `run_series_logs/` attempt logs, which have start/end timestamps and the chosen GPU, cross-referenced with `<projects>/gpu_usage_logger/gpu_usage.csv` if it exists (per-GPU `mem_used_mib` over time).
   - Or `results.md` entries.
3. Nothing measured: estimate peak GPU memory from parameter count × bytes per param (plus optimizer state if training, plus a KV/activation allowance). Ask the user for a runtime estimate. Mark the row as **unmeasured** in the Step 6 table.

**Pick the GPUs:**
- Required memory = measured peak × 1.15 + 2 GB.
- Candidates are SKUs whose `gpu_mem` ≥ required memory, minus cc 7.x if the run uses bf16.
- Exclude H100 unless it's the only candidate that fits, or the walltime on cheaper GPUs would exceed 48 h. Don't occupy H100s needlessly.
- The final constraint is an OR over the remaining SKUs, for example `gpu_sku:L40S|gpu_sku:A100`, so the scheduler can use whichever is free.
- **Check live availability before settling the list:** `sinfo --clusters=htc -p <partition> -h -o '%G %t %D' | sort | uniq`. Count only `idle`/`mix` nodes, since `drain`/`resv`/`alloc` nodes can't take the job.
  - If the cheapest SKUs have only a few `idle`/`mix` nodes, include L40S. It's the largest pool, with 24 nodes.
  - After submitting, check `squeue --clusters=htc -j <id> --start`. If the estimated start is more than a few hours away, widen the constraint while the job is still pending with `scontrol update --clusters=htc JobId=<id> Features="<new OR list>"`, with user confirmation, and update `REQ_CONSTRAINT` in `job.env`.
  - On 2026-10-28 a constraint of V100, Titan RTX, RTX8000 and A6000 gave an estimated start 6 days out, while 18 L40S nodes were partly free.

**Walltime:**
- The slowdown for each candidate GPU is `max(835 / TFLOPS_target, 3.9 / BW_target)` relative to morph's H100 NVL. Taking the larger of the compute and bandwidth ratios is the conservative choice.
- From ledger evidence for the same SKU, use slowdown 1.
- Walltime = (local runtime × slowdown of the **slowest** GPU in the constraint × 1.25) + 15 min setup (env check, HF download, model load). Round up to the next 15 min.
- If one slow SKU inflates the walltime by more than 1.5× compared with dropping it, drop it from the constraint.
- Partition: the shortest that fits (`short` up to 12 h, then `medium` up to 48 h, then `long`). Check that the chosen SKUs exist in that partition.
- If the job needs more than 48 h, raise it with the user. It needs checkpointing, or a split across jobs with `--dependency=afterok`.

**Group priority QoS (`--qos=math-lasr`): the preferred default for GPU jobs.** This is the math-lasr group's priority access to H100s, and the user wants it used by default.
- It has priority 5000, against the default `standard` QoS and the paid `priority` QoS at 1000.
- It's capped at **4 GPUs at once for the whole group** (`GrpTRES=gres/gpu=4`), shared by every math-lasr member.
- **Default:** `--qos=math-lasr --constraint='gpu_sku:H100'`. Do the walltime with the H100 slowdown (slowest variant: 756 TFLOPS, 2.0 TB/s), which gives a shorter request. The GPU count and memory rules above still apply, so request only what the job uses.
- **Check group capacity first:** `squeue --clusters=htc -h -q math-lasr -o "%u %T %b %M %l"`. Free slots = 4 − the GPUs held by RUNNING jobs.
  - If enough slots are free, use the QoS.
  - If not, the job would wait until a group job finishes (its remaining time is `%l` − `%M`). Compare that wait with the standard-queue start estimate for the cheaper-GPU constraint, and recommend whichever starts sooner. Show both options in Step 6.
  - Also count PENDING group jobs with higher priority (`sprio --clusters=htc -j <ids>`). They take freed slots first, so a large one queued ahead can add its whole walltime to the wait. This is normally a quick check, since long jobs holding every group slot are unusual.
  - QoS can be switched on a pending job: `scontrol update --clusters=htc JobId=<id> QOS=<qos>`.
- Show the QoS choice, the group's current usage, and the slots this job takes as rows in the Step 6 table. Flag it when the job would take the last free group slot.
- CPU-only jobs don't use this QoS.

**CPU and memory:**
- `--cpus-per-task` = DataLoader `num_workers` + 1, minimum 2, default 4.
- `--mem` = max(16G, measured host peak × 1.3), rounded up to 4G. If unmeasured, use the larger of 2× the model weights in load dtype and 16G.

## Step 6: Present the plan and wait for confirmation
Show:
1. The hyperparameter table (Hyperparameter / Value / Source).
2. A resource table: one row each for partition, GPUs and constraint, walltime, CPUs, memory, and estimated slowdown per SKU. For each row give the value, the evidence it came from, and the formula.
3. The code SHAs per repo, the data being synced (with size), and the results paths that will be pulled back.
4. The ntfy topic: `NTFY_TOPIC` from config by default. Use a different one only if the user names it.

Wait for explicit confirmation in plain text. Submitting is billable and visible to others.

## Step 7: Write and submit
1. Create `$DATA/arc_jobs/<repo>/<job_name>/` on ARC. The `--output` directory must exist before submission. Create the local job dir too.
2. Fill in [reference/job_template.sh](reference/job_template.sh) to make `job.sbatch`:
   - `{{ARC_ACCOUNT}}`, `{{ARC_DATA}}` and `{{MAIL_USER}}` come from config.
   - `{{COMMAND}}` = `uv run --frozen --no-sync <confirmed command>`. `--no-sync` stops concurrent jobs racing on `.venv`.
   - `{{REMOTE_REPO}}` = `$DATA/code/<repo>` (spelled out).
   - `{{EXTRA_ENV}}` = any `export` lines the run needs, or empty.
   - Drop the `--constraint` line only if every SKU is acceptable.
3. Save it in the local job dir. Copy it to ARC with `scp` and Unix line endings. Submit with `ssh arc-htc 'sbatch --parsable <ARC_DATA>/arc_jobs/<repo>/<job_name>/job.sbatch'`. Afterwards, check that `squeue --clusters=htc -j <id> -h -o %a` shows `ARC_ACCOUNT`.
4. Write `job.env` in the local job dir with `JOB_ID JOB_NAME REMOTE_JOB_DIR NTFY_TOPIC LEDGER REPO COMMIT REQ_PARTITION REQ_CONSTRAINT REQ_TIME REQ_MEM REQ_CPUS REQ_GPUS` (absolute paths, `LEDGER=<projects>/.arc_jobs/ledger.jsonl` expanded).
5. Write `results.map` with one tab-separated line per results path: `$DATA/code/<repo>/<rel>/` → `<projects>/<repo>/<rel>/`, both absolute.
6. Start the watcher in detached tmux, never as a Bash background task:
   ```
   tmux new-session -d -s arc-<job_name> "bash ~/.claude/skills/arc-submit/scripts/watch_job.sh <local_job_dir>"
   ```

## Step 8: Report
Tell the user:
- the job ID, the queue position (`squeue --clusters=htc -j <id> --start` gives the estimated start time), and the requested resources
- where the logs are: `$DATA/arc_jobs/<repo>/<job_name>/slurm-<id>.out`, copied locally to `<local_job_dir>/remote/` when the job finishes
- what notifies them:
  - ntfy pushes from the watcher on the local machine (compute nodes can't reach ntfy.sh): when the job starts, when under 15 min of walltime is left, and when it finishes, with results pulled
  - Slurm email on END or FAIL to `MAIL_USER`
- how to cancel: `ssh arc-htc scancel --clusters=htc <id>`
- how to check on the watcher: `tmux capture-pane -t arc-<job_name> -p | tail`

Don't poll the job yourself unless asked.

## Sweeps
For N configurations, prefer a Slurm **job array** over N separate scripts, sized from the largest config: `--array=0-<N-1>%<max_concurrent>`, and keep `%<max_concurrent>` at 4 or lower unless the user asks for more. Each array task reads its config by `$SLURM_ARRAY_TASK_ID`. Show all configs in Step 6.

## After a run: calibrate
When a ledger entry exists for a new submission of the same experiment, compare the requested resources with what was used. If the job used less than 50% of its walltime or memory, shrink the next request toward the actuals (keeping the ×1.25 and ×1.15 margins). If it hit `TIMEOUT` or `OUT_OF_MEMORY`, raise the request and say so explicitly.
