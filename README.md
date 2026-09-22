# agentbox

Run AI coding agents (Claude Code, Codex, opencode) with no permission prompts, inside a Docker container that can only see the project you started it from.

```bash
cd my-project && agentbox   # opens a sandbox shell for this project
claude                      # or: codex, opencode
```

Each project gets its own box. The box keeps that project's agent logins, history and installed dependencies between sessions; everything else is thrown away when you exit.

**Contents:** [Requirements](#requirements) · [Quick start](#quick-start) · [Everyday use](#everyday-use) · [Logging in your agents](#logging-in-your-agents) · [Project dependencies](#project-dependencies) · [Configuring a project](#configuring-a-project-agentbox) · [Bind mounts](#bind-mounts-what-the-box-sees-of-your-machine) · [What persists](#what-persists) · [Security model](#security-model) · [Platform notes](#platform-notes) · [Troubleshooting](#troubleshooting) · [Updating](#updating) · [Uninstalling](#uninstalling) · [Contributing](#contributing) · [License](#license)

## Requirements

- **Docker**, one of: macOS — [Docker Desktop](https://www.docker.com/products/docker-desktop/) or [OrbStack](https://orbstack.dev); Linux — Docker Engine, with yourself added to the `docker` group (`sudo usermod -aG docker $USER`, then log out and back in); Windows — WSL2 with Docker Desktop, WSL integration enabled for your distro (Docker Desktop → Settings → Resources → WSL integration) and agentbox run inside WSL.
- **git** and **bash** (the ones your system ships are fine).
- **About 6 GB of disk** (image ~4.5 GB, plus a little per project). Optional: `curl` and `jq`, only for `agentbox versions`.

## Quick start

**1. Get agentbox and install it.**

```bash
git clone https://github.com/narragen/agentbox.git && ./agentbox/install.sh
```

Clone it anywhere you like, but **keep the folder**: the installed `agentbox` command is a link back into it. The installer links `agentbox` into `~/.local/bin` and adds that folder to your `PATH` in `~/.zshrc` (zsh) or `~/.bashrc` / `~/.bash_profile` (bash) if it isn't there yet (other shells: it tells you what to add). It also creates `~/.config/agentbox/env` for your tokens (private to you) and `~/.config/agentbox/binds` for optional extra mounts, and builds the Docker image — **the first build takes several minutes**. Then **open a new terminal** so the `PATH` change applies.

**2. Add your tokens** (details in [Logging in your agents](#logging-in-your-agents)). Open `~/.config/agentbox/env` and fill in what you use — one `KEY=value` per line, no quotes, e.g. `GH_TOKEN=github_pat_...` and `CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...`. On macOS with a Claude subscription, `CLAUDE_CODE_OAUTH_TOKEN` is effectively required; without it you log in to Claude again in every project.

**3. Start a box** from a project folder (`cd my-project && agentbox`; agentbox refuses to open your home folder or `/`, which would expose your SSH keys and credentials). The first launch in a project installs its dependencies (see [Project dependencies](#project-dependencies)) and prints `agentbox ready. Agents run without permission prompts; the container is the boundary.` You're now in a shell inside the box, in `/workspace` — your project folder. Check it:

```bash
echo $AGENTBOX          # prints 1: you're inside a box
claude                  # starts without asking for permission for each command
```

The first run of an agent in a project may show first-run screens (theme, trusting the folder); that happens once per project. Claude Code's usual warning about running without permission prompts is skipped in the box: starting agentbox is that choice.

**4. Leave, and come back.**

- `exit` leaves the shell. Exiting the first shell `agentbox` opened stops the box, including any other shells joined to it.
- Run `agentbox` in the same folder to come back; logins and installed dependencies are still there.
- Run `agentbox` in a second terminal while the box is running to open another shell in the same box.

## Everyday use

| Command | What it does |
|---|---|
| `agentbox` or `agentbox DIR` | Open (or join) the box for the current folder, or `DIR` |
| `agentbox init` | Create `.agentbox/` with example settings (see [Configuring a project](#configuring-a-project-agentbox)) |
| `agentbox build` | Rebuild the image now. `agentbox` also does this automatically when needed |
| `agentbox clean [-y]` | Delete this project's box: logins, history, installed dependencies and its project image. Exit the box first. Asks before deleting unless `-y` |
| `agentbox update [--no-build] [--force]` | Pull the latest agentbox from the remote, reinstall, and rebuild the image. See [Updating](#updating). |
| `agentbox versions [--apply]` | Check the pinned tool versions (see [Updating](#updating)) |
| `agentbox version` | Show the agentbox version and tool versions, e.g. for a bug report |

| In the box | What it does |
|---|---|
| `claude`, `codex`, `opencode` | Start an agent, with permission prompts off |
| `agentbox-deps` | Reinstall dependencies after you change a dependency file (`--force`: even if nothing changed) |
| `exit` | Leave. In the first shell of a box, this stops the box |

**Pass extra flags to Docker.** `--docker-arg` forwards arguments to the underlying `docker run` command. Repeat for each flag:

```bash
agentbox --docker-arg --network host --docker-arg -e FOO=bar
```

This is useful for debugging or custom network configurations.

## Logging in your agents

Each project's box has its own logins: an agent you log in to *inside* a box stays logged in for that project only. Tokens in `~/.config/agentbox/env` work in every box. The env file takes one `KEY=value` per line, **no quotes** (Docker would keep them as part of the value), no `export`; empty values of the keys below are ignored.

| Key | What it's for | How to get it |
|---|---|---|
| `GH_TOKEN` | GitHub auth in the box: `gh` and `git push`/`pull`. See below | GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens. Give it access to the repos you want agents to push to, nothing more |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code with a Claude Pro/Max subscription, in every box | Run `claude setup-token` **on your own machine** (install Claude Code there first), and paste the token it prints |
| `ANTHROPIC_API_KEY` | Claude Code with an API key instead of a subscription | console.anthropic.com |
| `OPENAI_API_KEY` | opencode with an OpenAI key. For Codex, also run `printenv OPENAI_API_KEY \| codex login --with-api-key` once in the box | platform.openai.com |
| `CODEX_ACCESS_TOKEN` | Logs Codex in on a box's first launch | Only if you already have one; otherwise log in inside the box |

**GitHub auth.** The designed method is a fine-grained PAT in `~/.config/agentbox/env` as `GH_TOKEN`. The box has no SSH keys; when `GH_TOKEN` is set, agentbox rewrites GitHub SSH remotes to HTTPS at launch and configures `gh` as the git credential helper, so `gh`, `git push` and `git pull` all just work (`gh` reads `GH_TOKEN` natively — GitHub's recommended way to use fine-grained PATs). Without `GH_TOKEN`, SSH remotes fail (no keys) and `gh` is unauthenticated.

Per agent:

- **Claude Code.** With `CLAUDE_CODE_OAUTH_TOKEN` set, you're logged in everywhere. Without it, run `claude` in the box and follow the login link; that login is kept for this project only. On Linux, a Claude Code login on your machine is shared with the box (`~/.claude/.credentials.json`). On macOS the login lives in the Keychain, which the box can't read, so use the token.
- **Codex.** If your machine has `~/.codex/auth.json` (Codex's file-based login), every box uses it. Otherwise run `codex login --device-auth` in the box: it prints a code to enter in your browser.
- **opencode.** Run `opencode auth login` in the box, or set the provider's API key in the env file.

## Project dependencies

At launch, agentbox installs your project's dependencies into storage owned by the box (not your project folder), so they survive relaunches and never mix with dependencies on your machine. Unchanged dependency files skip this step.

| Your project has | agentbox runs |
|---|---|
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` (pnpm switches to the version in `packageManager`, if set) |
| `yarn.lock` | `yarn install`, frozen to the lockfile (the version in `packageManager` is used) |
| `bun.lock` or `bun.lockb` | `bun install --frozen-lockfile` |
| `package-lock.json` or `npm-shrinkwrap.json` | `npm ci` |
| `package.json` and no lockfile | `npm install` (this creates `package-lock.json` in your project) |
| `pyproject.toml` with a `[project]` table | `uv sync --locked` (plain `uv sync` if there's no `uv.lock`, which creates one) |
| `requirements.txt` and/or `requirements-dev.txt` | a fresh virtualenv, then `uv pip install -r ...` |

- **Lockfiles are respected.** If `package.json` and the lockfile disagree, the install fails with a clear message instead of rewriting the lockfile. The shell still opens: fix the lockfile, then run `agentbox-deps`.
- **Python:** the virtualenv is active in every shell (`python` is the project's). `.python-version` is honoured, and uv downloads that Python if needed. If a folder has both `pyproject.toml` and `requirements.txt`, `pyproject.toml` wins. Poetry-only `pyproject.toml` files (no `[project]` table) are skipped; use `setup.sh` for those.
- **Bun global installs** (`bun i -g`) go to `~/.bun` inside the box, which is not on the box `PATH` and doesn't persist — install project dependencies instead.
- **Not supported yet:** pnpm/npm/yarn/bun workspaces (monorepos). agentbox skips that folder with a message; such installs would write into your project folders on your machine. A `pnpm-workspace.yaml` that only holds settings (no `packages:`) is fine.
- **Where it looks:** the project root by default; `NODE_DIRS` and `PYTHON_DIR` in `.agentbox/config` point elsewhere (see [Configuring a project](#configuring-a-project-agentbox)).

## Configuring a project (`.agentbox/`)

Everything here is optional. `agentbox init` creates a `.agentbox/` folder with examples; keep the files you need and commit them. Files ending in `.example` do nothing until you remove that suffix. The two agent files `init` creates already make Claude Code and opencode **ask before `git push`**; delete them if you don't want that. These files apply only inside the box: agents run directly on your machine ignore them. "Next time a box starts" means after **every** shell of the box has exited; running `agentbox` while a box is open just joins it.

| File | What it does | Takes effect |
|---|---|---|
| `config` | Which folders hold dependencies (`NODE_DIRS`, `PYTHON_DIR`) | Next time a box starts |
| `claude.settings.json` | Claude Code settings for this project's box, e.g. commands to deny or ask about | Next `claude` |
| `opencode.jsonc` (or `.json`) | opencode settings for this project's box, merged on top of the repo's `opencode.json` | Next `opencode` |
| `codex.config.toml` | Codex settings (model, reasoning effort) for this project's box. Starts from `codex.config.toml.example` | Next `codex` |
| `setup.sh` | A script run in the box on every start, after the dependency installs | Next time a box starts |
| `Dockerfile` | Extra tools for this project, built on top of the agentbox image | Next time a box starts |

**A repo with `frontend/` and `backend/`** — `.agentbox/config`:

```
NODE_DIRS=frontend
PYTHON_DIR=backend
```

`NODE_DIRS` takes several folders separated by spaces (`NODE_DIRS=frontend tools`); each gets its own `node_modules` storage. `PYTHON_DIR` takes one folder. The file is read as plain settings, never run as a script.

**Make agents ask before `git push`.** Permission prompts are off in the box, but rules you add still apply: `deny` blocks a command, `ask` brings the prompt back for it.

`.agentbox/claude.settings.json`:

```json
{
  "permissions": { "deny": ["Bash(npm publish:*)"], "ask": ["Bash(git push:*)"] }
}
```

`.agentbox/opencode.jsonc`:

```jsonc
{
  "permission": { "bash": { "git push *": "ask" } }
}
```

Codex has no equivalent inside the box (see [Security model](#security-model)).

**Add a language or tool.** For one project, use `.agentbox/Dockerfile` for the tool and `.agentbox/setup.sh` for anything to run at startup. For example, Go:

`.agentbox/Dockerfile`:

```dockerfile
ARG AGENTBOX_IMAGE
FROM ${AGENTBOX_IMAGE}
COPY --from=golang:1.27.1-bookworm /usr/local/go /usr/local/go
# Caches live in the project so they survive the box (add .cache/ to .gitignore).
ENV PATH=/usr/local/go/bin:/home/node/go/bin:$PATH GOMODCACHE=/workspace/.cache/go/mod GOCACHE=/workspace/.cache/go/build
```

`.agentbox/setup.sh` (optional; here the Go module lives in `backend/`):

```bash
cd backend && go mod download
```

Everything outside `/workspace` is wiped when the box exits, which is why the caches point into the project. Set environment variables with `ENV` in the Dockerfile: variables exported in `setup.sh` don't reach your shell or the agents. The first time agentbox sees a project's `setup.sh` or `Dockerfile`, and whenever either changes, it shows you the file and asks before running it.

To add a language for **every** project, add its toolchain to `image/Dockerfile` and an installer `image/deps.d/NN-name.sh` modelled on `10-node.sh`.

## Bind mounts: what the box sees of your machine

A bind mount is a file or folder from your machine that is visible inside the box. Some are mounted by default, when they exist on your machine:

| Mounted | Access |
|---|---|
| `~/.claude/CLAUDE.md`, `settings.json`, `skills/`, `agents/`, `commands/` | read-only |
| `~/.claude/.credentials.json`, `~/.codex/auth.json` (logins) | read-write (the agents refresh them) |
| `~/.codex/AGENTS.md` | read-only |
| `~/.config/opencode/`: `opencode.json(c)`, `AGENTS.md`, `agent/`, `command/` | read-only |
| Your git name and email | read-only copy. Nothing else from your git config |

To share more, list extra files or folders in `~/.config/agentbox/binds`, one `SOURCE:DEST` per line (blank lines and `#` comments are ignored), optionally followed by `:ro` (read-only, the default) or `:rw`:

```
~/.claude/statusline-command.sh:/home/node/.claude/statusline-command.sh
~/.claude/memory:/home/node/.claude/memory:rw
```

Rules: `~` expands to your home folder in the source only (a `~` in the destination is rejected); the source must be absolute or start with `~`; the destination must be absolute; no commas; a missing source is skipped with a warning, not created. Bind changes take effect at the **next launch** — a running box keeps its current mounts.

The security meaning: anything mounted `:rw` can be written by code in **every** box, including projects you don't trust — use `:rw` sparingly. Even read-only mounts are readable by anything in the box, and the box's network is open, so mount only what that project should see.

## What persists

| In the box | Lifetime |
|---|---|
| `/workspace` | Your project folder itself |
| Agent logins and history (`~/.claude`, `~/.codex`, `~/.local/share/opencode`) | Kept per project until `agentbox clean` |
| `node_modules`, the Python virtualenv | Kept per project until `agentbox clean` |
| Everything else, including `/tmp` and the rest of `~` | Wiped when the box stops |

What comes from your machine instead is the set of [bind mounts](#bind-mounts-what-the-box-sees-of-your-machine) above.

## Security model

**Protected** (the container is the boundary):

- Files outside the project folder (apart from the [bind mounts](#bind-mounts-what-the-box-sees-of-your-machine)), your other projects, your SSH keys, and other credentials on your machine.
- Root access. The box always runs as an unprivileged user with no `sudo`, even if a project's `Dockerfile` ends as root.

**Not protected:**

- **Network access is open.** Anything the box can read can be sent out, including your project's `.env` files and the tokens in `~/.config/agentbox/env`. Use narrowly scoped tokens, and never put production credentials in either place.
- **Your project's `.git` folder is writable.** Code in the box could add a git hook or a git setting that runs a program the next time *you* use git on your machine. When a box exits, agentbox checks for new or changed hooks and program-running git settings, and prints a warning if it finds any. It warns; it can't prevent them.
- **Repos you didn't write.** A project's `.agentbox/setup.sh`, `.agentbox/Dockerfile` and npm install scripts run automatically at launch, with your tokens available. agentbox asks before running a new or changed `setup.sh` or `Dockerfile`, but not before npm install scripts (the same as running `npm install` yourself). Read unfamiliar repos before opening them in a box.
- **Read-write mounts.** Files you mount `:rw` can be changed by any box (see [Bind mounts](#bind-mounts-what-the-box-sees-of-your-machine)).

**Guardrails the project can't turn off:**

- Agents can't run `git worktree prune`, `remove` or `move`, and `git gc` is set never to prune worktrees. Inside a box, the project's other git worktrees look deleted, and those commands would erase their records.
- Claude Code is denied reading `.env` files directly. This is a courtesy, not a wall: a shell command could still print them.

**Codex:** its own sandbox needs a kernel feature Docker blocks, so the box turns it off and relies on the container, as it does for the other agents. That also means permission and network rules in `codex.config.toml` aren't enforced. The worktree guardrail still applies.

## Platform notes

- **macOS:** works with Docker Desktop and OrbStack. Use `CLAUDE_CODE_OAUTH_TOKEN` for Claude Code (see [Logging in your agents](#logging-in-your-agents)).
- **Linux:** the image is built so the box's user has your user and group IDs, which keeps files the agents create owned by you. On a machine where several Linux users share one Docker daemon, the image is built for whoever built it last. Rootless Docker and Podman are untested. On SELinux systems (Fedora, RHEL) mounts may be blocked; this isn't handled yet.
- **WSL2:** keep projects inside the Linux filesystem (`~/...`); `/mnt/c/...` works but is slow.
- **git worktrees:** supported; start the box from the worktree's folder. Worktrees created with `worktree.useRelativePaths` aren't; agentbox tells you how to convert them.
- **Start from the repo root.** From a subfolder of a git repo the box works, but git doesn't work inside it (agentbox warns you).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `can't reach the Docker daemon` | Docker isn't running. Start Docker Desktop (or `sudo systemctl start docker`), then run the command again. |
| `Docker isn't responding` | The daemon is up but not answering, usually still starting. Wait for Docker to finish starting and run the command again; agentbox waits a few seconds (`AGENTBOX_DOCKER_TIMEOUT` to change). |
| `you don't have permission to use it` | Linux: `sudo usermod -aG docker $USER`, then log out and back in. |
| `command not found: agentbox` | Open a new terminal after installing, or add `~/.local/bin` to your `PATH`. |
| `needs an interactive terminal` | Run `agentbox` in a normal terminal tab, not through a pipe, an IDE task, or an agent's shell. |
| Launch seems stuck after `building agentbox:latest` or `checking the image` | The first build, and the first launch after updating agentbox, take several minutes. |
| `image build failed; starting the EXISTING ...` | The rebuild failed (often network). You're on the previous image; run `agentbox build` to see the error. |
| `dependency setup FAILED in: ...` | The lines above it say which folder. Usually a manifest and its lockfile disagree: `package.json` vs its lockfile (fix it in the box with `npm install`, `pnpm install`, `yarn install` or `bun install`), or `pyproject.toml` vs `uv.lock` (`uv lock`). Then run `agentbox-deps`. |
| `part of a pnpm/npm/yarn/bun workspace` | Monorepo workspaces aren't supported yet. The box still works; that folder's dependencies aren't installed. |
| `refusing to open ...` | You started agentbox in your home folder (or `/`). `cd` into a project folder first. |
| Claude Code hook or status line errors in the box | Your `~/.claude/settings.json` is shared with the box, and hooks or a status line that call programs or paths from your machine don't exist inside it. Mount what they need via `~/.config/agentbox/binds`, or make them tolerate being absent. |
| An agent asks you to log in again | Logins are per project. Use a token in `~/.config/agentbox/env`, or log in once in this project's box. `agentbox clean` also removes logins. |
| `... is readable by other users` | `chmod 600 ~/.config/agentbox/env` |
| `not approved: .agentbox/setup.sh` | You declined to run it. Run `agentbox` again and answer `y` if the file is fine. |
| `WARNING: the box changed git hooks or git config` | Something in the box added or changed a git hook or a program-running git setting. Inspect `.git/hooks` and `.git/config` before using git on your machine. |
| `removed stray core.worktree=/workspace` | A tool in the box wrote a container-only path into your git config; agentbox removed it. Nothing to do. |
| Dependencies look stale | Run `agentbox-deps --force` in the box. For a completely fresh start, exit and run `agentbox clean`. |

## Updating

**Updating agentbox:** run the update command from anywhere:

```bash
agentbox update                       # pull, reinstall, rebuild
agentbox update --no-build            # same, but skip the image build
agentbox update --force               # skip the breaking-change confirmation
```

This pulls the latest from the remote, reinstalls the symlink and PATH entry, preserves your config (`~/.config/agentbox/env`, `~/.config/agentbox/binds`, approvals), and rebuilds the Docker image. On a major version bump it shows `BREAKING_CHANGES.md` and asks for confirmation before proceeding.

**Newer tool versions:** every tool version is pinned in `versions.env` — except `gh`, which comes from GitHub's apt repo and is not pinned — so a pull decides what you get. Maintainers bump the pins with:

```bash
agentbox versions            # compare with npm, GitHub and PyPI
agentbox versions --apply    # write the newer versions into versions.env
agentbox build
```

If you run `--apply` in a plain clone, your `versions.env` will then differ from upstream and `git pull` may conflict. Commit it on a branch, or `git checkout versions.env` before pulling. `NODE_VERSION` and `PYTHON_VERSION` are deliberate choices and are never bumped automatically. `PLAYWRIGHT_VERSION` waits until Microsoft publishes the matching image.

## Uninstalling

Exit all boxes first, then run the uninstaller from the folder you cloned (`cd` there first):

```bash
./install.sh --uninstall                        # removes the agentbox command
rm -rf ~/.config/agentbox ~/.cache/agentbox     # tokens, mounts list, approvals
docker volume ls -q | grep '^agentbox-' | xargs -r docker volume rm   # all boxes' data
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^agentbox(-proj)?:' | xargs -r docker image rm
```

Then remove the `# added by agentbox install.sh` line, and the `export PATH` line under it, from your shell's startup file (`~/.zshrc`, `~/.bashrc` or `~/.bash_profile`), and finally delete the cloned folder.

## Contributing

```
bin/agentbox         the command you run
lib/common.sh        its helpers (naming, config parsing, git checks, approvals)
image/               the Docker image: Dockerfile, entrypoint, dependency installers, agent wrappers (zshrc), guardrail policies
templates/           files `agentbox init` copies
scripts/             update.sh, versions.sh
tests/               run-all.sh (no Docker needed), integration.sh (needs the image)

# tests
bash tests/run-all.sh                         # a few seconds
/bin/bash tests/run-all.sh                    # macOS: also checks bash 3.2
agentbox build && bash tests/integration.sh   # several minutes; needs network
```

CI runs shellcheck and the host tests on Linux and macOS, then builds the image and runs the integration tests. When reporting a problem, include the output of `agentbox version`, your OS, and your Docker flavour (Docker Desktop, OrbStack, Docker Engine).

## License

[MIT](LICENSE) © Narragen.
