# Agent Development Workflow

## Before Pushing

Always run these locally before pushing to a PR:

```bash
# 1. Run all host tests
bash tests/run-all.sh

# 2. Run shellcheck (install if needed: brew install shellcheck / sudo apt install shellcheck)
shellcheck -x -s bash -S warning \
  bin/agentbox lib/common.sh install.sh scripts/update.sh scripts/versions.sh \
  image/entrypoint.sh image/agentbox-deps image/zshrc image/guard-git-worktree.sh \
  image/deps.d/*.sh image/Dockerfile tests/*.sh
```

All CI jobs must pass before requesting review. The CI mirrors the local commands above:
- `shellcheck + host tests (Linux)` — shellcheck + `bash tests/run-all.sh`
- `host tests (macOS bash 3.2)` — `/bin/bash tests/run-all.sh`
- `build image + integration test` — `bin/agentbox build` + `bash tests/integration.sh` (requires Docker)

## Test Structure

- `tests/assert.sh` — assertion helpers (source before use)
- `tests/run-all.sh` — runs all `test-*.sh` suites
- Each `test-*.sh` file tests one area: cli, config, deps, docker-stub, guard, install, update-cli, versions

## Common Pitfalls

- Changing a Dockerfile `ARG` that appears in `versions.env` requires updating the test in `test-config.sh` that validates the correspondence.
- The `(=|$)` alternation in sed does not work correctly in all sed versions; use `(=.*)?` instead.
- macOS uses bash 3.2 — avoid bash 5+ features in scripts.
