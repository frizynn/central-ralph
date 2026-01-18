# GRALPH

![gralph](assets/gralph.png)

GRALPH is a parallel AI coding runner that executes tasks across multiple agents in isolated git worktrees.

## Overview

GRALPH reads task definitions, schedules them with dependencies and mutexes, and runs multiple agents in parallel. Each task produces artifacts (logs and reports) and commits work to isolated branches.

## Features

- DAG-based task scheduling with dependencies and mutexes
- Parallel execution in isolated git worktrees
- Per-task artifacts (JSON reports and logs)
- Integration branch merging with conflict resolution
- Support for Claude Code, OpenCode, Codex, and Cursor

## Requirements

- One of: Claude Code CLI, OpenCode CLI, Codex CLI, or Cursor (`agent` in PATH)
- `jq`
- Optional: `yq` (YAML task files), `gh` (GitHub Issues/PRs), `bc` (cost estimates)

## Setup

```bash
# From your project root
mkdir -p scripts/gralph
cp /path/to/gralph/gralph.sh scripts/gralph/
chmod +x scripts/gralph/gralph.sh

# Install required skills for the selected engine
./scripts/gralph/gralph.sh --init
```

## Usage

```bash
# OpenCode: write PRD to PRD.md, then run gralph
./scripts/gralph/gralph.sh --opencode --parallel

# Use an existing tasks.yaml
./scripts/gralph/gralph.sh --yaml tasks.yaml --parallel

# Limit parallelism
./scripts/gralph/gralph.sh --parallel --max-parallel 2
```

## Configuration

| Flag | Description |
|------|-------------|
| `--parallel` | Run tasks in parallel |
| `--max-parallel N` | Max concurrent agents (default: 3) |
| `--external-fail-timeout N` | Seconds to wait after external failure (default: 300) |
| `--create-pr` | Create PRs instead of auto-merge |
| `--dry-run` | Preview only |

## Task Files

GRALPH supports `tasks.yaml` v1 format with dependencies and mutexes:

```yaml
version: 1
tasks:
  - id: SETUP-001
    title: "Initialize project structure"
    completed: false
    dependsOn: []
    mutex: ["lockfile"]
  - id: US-001
    title: "Build hero section"
    completed: false
    dependsOn: ["SETUP-001"]
    mutex: []
```

## Artifacts

Each run creates `artifacts/run-YYYYMMDD-HHMM/`:
- `reports/<TASK_ID>.json` - Task report
- `reports/<TASK_ID>.log` - Task log
- `review-report.json` - Integration review (if enabled)

## Code Location

Tasks run in isolated git worktrees and commit to feature branches. To inspect completed task code:

```bash
# Find branch in task report
cat artifacts/run-*/reports/TASK-ID.json | jq '.branch'

# Checkout the branch
git checkout <branch>
```

## Workflow

1) Ask your engine to write a PRD to `PRD.md`
2) Run gralph; it creates `tasks.yaml` and executes tasks
3) Inspect artifacts and merge/PR as needed

Engines:
- `--opencode`
- `--claude`
- `--cursor`
- `--codex`

Skills used by gralph:
- `prd`
- `ralph`
- `task-metadata`
- `dag-planner`
- `parallel-safe-implementation`
- `merge-integrator`
- `semantic-reviewer`

## Contributing

PRs and issues welcome. Keep changes small and update tests/docs when adding features.

## License

MIT

## Credits

Inspired by Ralph, which pioneered autonomous AI coding loops.