# ARC setup (sub-skill of arc-submit)

This walks a new user, or an existing user on a new local machine, through everything `arc-submit` needs. The result is a filled-in, verified [../config.env](../config.env), created from [../config.env.example](../config.env.example) (git-ignored, per-user).

Run it as a conversation: one step at a time, checking each step before moving on.
- Use the step's **Check** command to see whether it's already done, and skip any step that passes.
- Wherever a step says **User runs**, give the user the exact command to run themselves with the `!` prefix, which runs it on the local machine. Never ask them to paste a password, token, or API key into chat.
- Everything else, run yourself.

Keep [../reference/arc_rules.md](../reference/arc_rules.md) in force throughout. Docs: [connecting](https://arc-user-guide.readthedocs.io/en/latest/connecting-to-arc.html), [copying data](https://arc-user-guide.readthedocs.io/en/latest/arc-copying-data.html), [host keys](https://arc-user-guide.readthedocs.io/en/latest/arc-host-keys.html).

## Step 1: Collect the basics
Ask for:

| Value | Example | Note |
|---|---|---|
| ARC username | `abcd1234` | Not their SSO name. It comes from the ARC account email |
| ARC project / Slurm account | `math-lasr` | `$DATA` is `/data/<project>/<user>`. If they belong to several projects, ask which one to charge |
| Email for Slurm notices | university address | |
| Local projects root | `~/projects` | Where their repos live locally |
| ntfy topic | `<name>-arc-<random>` | Anyone who knows the topic can read it, so it must be unguessable. Suggest one; don't reuse another project's |

Prerequisites, which only the user can fix:
- **An ARC account and project membership.** If they don't have one, stop. They apply through the ARC account pages, which the [General FAQ](https://arc-user-guide.readthedocs.io/en/latest/general-faq.html) links to.
- **The university network or VPN.** Check with `timeout 10 bash -c '</dev/tcp/htc-login.arc.ox.ac.uk/22' && echo reachable`. If it's unreachable, they need the university VPN. External collaborators register a static IP with support@arc.ox.ac.uk and go through the gateway.

## Step 2: Local machine health
- `df -h /tmp ~` should show at least 1 GB free in each. A full `/tmp` silently truncates tool output.
- If `/tmp` is full, list what the user owns there (`find /tmp -maxdepth 1 -user $USER`) with sizes.
  - Skip live sockets: `tmux-*`, `vscode-*`, `mcp-*`, and any wandb/Claude files changed in the last day.
  - Delete the rest only with the user's go-ahead.
  - Files owned by other users are for the admins to deal with.
- Check that `ssh`, `rsync`, `scp`, `git`, `tmux` and `curl` are installed.

## Step 3: Local SSH key
**Check:** `ls ~/.ssh/id_ed25519.pub`.

If it's missing, the **user runs**: `! ssh-keygen -t ed25519 -C "<user>-arc"`. A passphrase is their choice. If they set one, they also need `ssh-agent` running so batch commands work. Don't overwrite an existing key.

## Step 4: Verify host keys, then install the key on ARC
1. Fetch the [host-keys page](https://arc-user-guide.readthedocs.io/en/latest/arc-host-keys.html). Compare its fingerprints with `ssh-keygen -lf <(ssh-keyscan -t ed25519 htc-login.arc.ox.ac.uk gateway.arc.ox.ac.uk 2>/dev/null)`. If they differ, **stop** and tell the user. Don't continue past a mismatched host key.
2. **User runs** both of these. They prompt for the ARC password. The gateway has its own separate home directory, so it needs its own copy of the key:
   ```
   ! ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@htc-login.arc.ox.ac.uk
   ! ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@gateway.arc.ox.ac.uk
   ```
   `$HOME` is shared between htc-login and arc-login, so one copy covers both login nodes.

## Step 5: SSH aliases
**Check:** `grep -E '^Host arc-(htc|gw)$' ~/.ssh/config`.

Append (never overwrite) one block per alias, then run `mkdir -p ~/.ssh/cm && chmod 700 ~/.ssh/cm && chmod 600 ~/.ssh/config`:
```
Host arc-htc
    HostName htc-login.arc.ox.ac.uk
    User <user>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ControlMaster auto
    ControlPath ~/.ssh/cm/%r@%h:%p
    ControlPersist 30m
    ServerAliveInterval 60
```
The `arc-gw` block is the same with `HostName gateway.arc.ox.ac.uk`. Keep `ControlPath` out of `/tmp`.

**Verify:**
- `ssh -o BatchMode=yes arc-htc 'hostname; echo $DATA; myquota'` should report an `htc-login*` hostname, a `$DATA` that matches `/data/<project>/<user>`, and the quota table.
- `ssh -o BatchMode=yes arc-gw 'test -w /data/<project>/<user> && echo writable'` should print `writable`.

If `$DATA` doesn't match the project the user gave, ask which one is right.

**Accounts:** `ssh arc-htc 'sacctmgr -n -P show assoc user=$USER format=cluster,account'` lists the projects they can charge, and `ls -d /data/*/$USER` lists their data areas.
- `ARC_ACCOUNT` must be one of the listed accounts for the `htc` cluster.
- `ARC_DATA` must be `/data/<ARC_ACCOUNT>/<user>`, whatever the login shell's `$DATA` says, because the login `$DATA` may belong to a different project.
- Every `sbatch`/`srun` passes `--account=<ARC_ACCOUNT>`.

## Step 6: ARC-side layout and shell
1. Create the working directories (lightweight, fine on the login node): `mkdir -p $DATA/code $DATA/arc_jobs $DATA/arc_setup $DATA/hf_cache $DATA/.cache/uv`.
2. **uv.** Check with `ssh arc-htc 'command -v uv || ls ~/.local/bin/uv'`. If it's missing, the **user runs** `! ssh arc-htc 'curl -LsSf https://astral.sh/uv/install.sh | sh'`. That only downloads a binary, with no compiling, so it's acceptable on the login node.
3. **`~/.bashrc`.** Look at it read-only. Any `HF_HOME`, `UV_CACHE_DIR`, `PIP_CACHE_DIR` or `CONDA_PKGS_DIRS` must point at directories that exist under `$DATA`, never under `$HOME` (quota of about 15 to 20 GB) or a nonexistent `/scratch/<user>`.
   - If a fix is needed, give the user a `sed -i.bak` command to run. Editing their remote shell startup file is theirs to approve.
   - Also have them append `export HF_TOKEN_PATH=$HOME/.cache/huggingface/token`.
   - Job scripts set all of these themselves, so `.bashrc` matters only for interactive use.

## Step 7: GitHub access from ARC
Code reaches ARC by `git clone` and `git fetch` on ARC, so ARC needs its own GitHub credential.

**Check:** `ssh arc-htc 'ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com'`. Output containing `successfully authenticated` means it's done.

If not:
1. The **user runs** `! ssh -t arc-htc 'ssh-keygen -t ed25519 -C "arc-<user>" -f ~/.ssh/id_ed25519'`. This key lives in ARC `$HOME`, which is private.
2. Then `! ssh arc-htc 'cat ~/.ssh/id_ed25519.pub'`, and they add the output as a GitHub SSH key under Settings → SSH and GPG keys.
3. Re-check.

Repos with an `https://` origin (public) need nothing extra.

## Step 8: HF and W&B credentials
Tokens go in ARC **`$HOME`**, which is private. `$DATA` is group-readable, so never put them there.

**Check:** `ssh arc-htc 'ls ~/.cache/huggingface/token; grep -oE "machine [^ ]+" ~/.netrc'`. This lists only file names and hosts, never secrets.

- **HF:** if a token already exists locally (`~/.cache/huggingface/token`), the **user runs**:
  ```
  ! ssh arc-htc 'mkdir -p ~/.cache/huggingface && chmod 700 ~/.cache/huggingface' && scp ~/.cache/huggingface/token arc-htc:.cache/huggingface/token && ssh arc-htc 'chmod 600 ~/.cache/huggingface/token'
  ```
  Otherwise they create a read token at huggingface.co/settings/tokens and run `! ssh -t arc-htc 'uvx --from huggingface_hub hf auth login'`.
- **W&B:** the `.netrc` host must match the wandb version the repos pin (`grep -A1 '^name = "wandb"' <repo>/uv.lock`).
  - Older versions (0.22 and earlier, as Concept_Activation_Transport pins) authenticate against **`api.wandb.ai`**.
  - Recent standalone `wandb login` writes `api.forge.coreweave.com` instead, which the older versions ignore. That leaves jobs logging in anonymously, with `viewer: None`.
  - Preferred fix: if the local `~/.netrc` holds only W&B entries (check `grep -oE 'machine [^ ]+' ~/.netrc`), the **user runs** `! { echo; cat ~/.netrc; } | ssh arc-htc 'cat >> ~/.netrc && chmod 600 ~/.netrc'`.
  - Otherwise: `! ssh -t arc-htc 'uvx wandb login --host https://api.wandb.ai'`.

## Step 9: Test from a compute node (devel, 3 min, 1 CPU, 1 GB)
1. Fill `{{ARC_ACCOUNT}}` and `{{ARC_DATA}}` into [nettest.sbatch](nettest.sbatch) and [credtest.sbatch](credtest.sbatch). Copy both to `$DATA/arc_setup/`, `sbatch --parsable` each, and wait with a background `until` loop that polls `squeue` every 20 s or more, never in the foreground.
2. **nettest:** HF, W&B, GitHub and PyPI should return a non-`000` code. ntfy.sh returned `000` (blocked) on 2026-10-28. That's expected, because the local watcher sends notifications.
   - If HF or W&B returns `000`, compute nodes have no internet. Set `COMPUTE_INTERNET=no`.
   - Tell the user that arc-submit will then need models pre-staged into `$DATA/hf_cache`, and `WANDB_MODE=offline` with a sync after the job.
3. **credtest:** expect `HF: <hf-username>` and `WANDB: {... 'username': ...}`. Show the user both identities to confirm they're the right accounts.
4. Afterwards, delete the test logs in `$DATA/arc_setup/`.

## Step 10: Notifications
`curl -s -d "arc-submit setup test" https://ntfy.sh/<topic> -o /dev/null -w '%{http_code}'` should return 200. Ask the user to confirm they received it, either by subscribing in the ntfy app or with `curl -s https://ntfy.sh/<topic>/json`.

## Step 11: Write the config and finish
1. Write [../config.env](../config.env) with every key filled in, including `ARC_ACCOUNT`. Set `GATEWAY_KEY_OK`, `COMPUTE_INTERNET`, and `SETUP_VERIFIED=<today>`.
2. `mkdir -p <projects>/.arc_jobs`.
3. Save a short memory note: ARC user, SSH aliases, and any quirks found, such as the `.netrc` host or a fixed `.bashrc`.
4. Report a pass/fail table covering Steps 2 to 10, and anything left for the user to do.

## Pitfalls already hit (2026-10-28)
- On htc the default partition is `long`, not `short`. Always pass `--partition`.
- The gateway has a separate home directory, so its key must be installed with its own `ssh-copy-id`.
- `mybalance` isn't available on htc-login.
- `du` over `$DATA` or big local data directories can take minutes. Avoid it, or run it in the background.
- The auto-mode permission check may block edits to remote shell startup files and copying credentials. Hand those steps to the user as `!` commands. Explain these commands to the user.
