# arc-submit

Claude Code skill that submits experiments from a local GPU machine to the Oxford ARC cluster (HTC, Slurm).

- [SKILL.md](SKILL.md): submission workflow
- [setup/SETUP.md](setup/SETUP.md): first-time setup for a new user or machine
- [reference/](reference/): ARC rules, GPU specs, sbatch template
- [scripts/watch_job.sh](scripts/watch_job.sh): local watcher (ntfy, result pull-back, usage ledger)

Install by cloning into `~/.claude/skills/arc-submit`, then copy `config.env.example` to `config.env` (or let the setup flow write it). `config.env` is per-user and git-ignored.
