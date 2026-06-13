# CodeHawaii Container Fleet — Usage Guide for AI Agents

Two public, multi-arch Docker images for AI agents that need a real toolchain or
a coding agent inside a throwaway container. Both are `linux/amd64` + `linux/arm64`,
run as a non-root `dev` user (uid 1000), and use `tini` as PID 1.

| Image | When to use it | GitHub | Pull |
|-------|----------------|--------|------|
| **omnidev** | Build / test / analyze an arbitrary repo in an isolated container (Python, Go, Node, C/C++). | https://github.com/CodeHawaii/omnidev | `docker pull ghcr.io/codehawaii/omnidev` |
| **omniagent** | Run a CLI coding agent (Claude Code, Codex, Aider, Goose, Crush) in a container. Built `FROM` omnidev, so it has the full toolchain too. | https://github.com/CodeHawaii/omniagent | `docker pull ghcr.io/codehawaii/omniagent` |

**Decision rule:** need to *run code/tests/builds* → `omnidev`. Need an *agent that
writes code* → `omniagent` (it includes everything omnidev has).

**Tags (both images):** `:latest` (recommended), `:edge` (newest `main` build),
`:sha-<commit>` (immutable pin). No semver tags are published yet.

---

## omnidev — universal build / test / sandbox toolbox

- **GitHub:** https://github.com/CodeHawaii/omnidev
- **Image:** `ghcr.io/codehawaii/omnidev:latest`
- **Purpose:** one image to clone and build/test/analyze repositories across
  multiple language ecosystems, isolated from the host.

**What's inside** (base `debian:trixie-slim`, glibc):

| Tool | Version | Tool | Version |
|------|---------|------|---------|
| Python | 3.13 (+ `pip`, `venv`) | Node.js | 24.16 LTS |
| uv / uvx | 0.11.x | pnpm / yarn | via corepack |
| Go | 1.26.x | gcc / g++ | 14 |
| make / cmake / pkg-config | ✓ | git / git-lfs / openssh | ✓ |
| jq / ripgrep (`rg`) / fd / tree | ✓ | curl / wget / unzip / xz | ✓ |

Env defaults: `LANG=C.UTF-8`, `GOPATH=/home/dev/go`, `GOTOOLCHAIN=local`,
`PNPM_HOME=/pnpm`, `UV_CACHE_DIR=/home/dev/.cache/uv`. Default workdir `/work`.

**Use it directly (you manage trust):**
```bash
# interactive
docker run --rm -it ghcr.io/codehawaii/omnidev bash

# build & test the current directory
docker run --rm -v "$PWD":/work -w /work ghcr.io/codehawaii/omnidev \
  bash -lc 'uv sync && uv run pytest -q'
```

### Running UNTRUSTED code — `sandbox-run.sh`

The repo ships a **host-side** wrapper `sandbox-run.sh` that runs the omnidev
image with defense-in-depth isolation (read-only rootfs, `--cap-drop ALL`,
`--security-opt no-new-privileges`, resource caps, **no network by default**),
copies the target repo into a throwaway run dir (your source is never mutated),
and collects logs + artifacts on the host. It is **not baked into the image** —
get it from the repo:

```bash
curl -fsSLO https://raw.githubusercontent.com/CodeHawaii/omnidev/main/sandbox-run.sh
chmod +x sandbox-run.sh
export OMNIDEV_IMAGE=ghcr.io/codehawaii/omnidev:latest

# run a test suite with NO network (default)
./sandbox-run.sh ~/code/somelib 'uv sync --offline && uv run pytest -q'

# allow network for dependency fetching
./sandbox-run.sh --net ~/code/somelib 'go test ./...'
```
Results land in `./omnidev-runs/<timestamp>/` (`run.log`, `exit_code`, `out/`,
`work/`). A container is process isolation, not a hard security boundary; for
stronger isolation set `OMNIDEV_RUNTIME=runsc` (gVisor) or use a microVM.

---

## omniagent — coding agents on the omnidev toolbox

- **GitHub:** https://github.com/CodeHawaii/omniagent
- **Image:** `ghcr.io/codehawaii/omniagent:latest`
- **Purpose:** a single container with the most popular CLI coding agents,
  pre-installed on top of omnidev. **Ships NO API keys** — provide credentials
  at runtime.

**Agents** (run `agents` inside the container to list them + detected keys):

| Agent | Command | Headless | Primary auth env var |
|-------|---------|----------|----------------------|
| Claude Code | `claude` | `claude -p "..."` | `ANTHROPIC_API_KEY` |
| OpenAI Codex | `codex` | `codex exec "..."` | `OPENAI_API_KEY` |
| Aider | `aider` | `aider --yes-always` | `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` (BYO) |
| Goose | `goose` | `goose run -t "..."` | provider key of choice |
| Crush | `crush` | `crush run "..."` | provider key of choice |

> Not included: Cline (omitted to stay lean), Gemini CLI (deprecated 2026-06-18),
> OpenCode / Continue (archived), Cursor CLI (proprietary).

**Authentication** — two ways, image bakes nothing:
```bash
# 1) env vars (CI / automation)
docker run --rm -e ANTHROPIC_API_KEY -v "$PWD":/work -w /work \
  ghcr.io/codehawaii/omniagent claude -p "summarize this codebase"

# 2) mount host config read-only (log in once on the host, reuse it)
docker run --rm -it -v ~/.codex:/home/dev/.codex:ro -v "$PWD":/work -w /work \
  ghcr.io/codehawaii/omniagent codex
```

**Examples:**
```bash
# what's installed + which keys are set
docker run --rm ghcr.io/codehawaii/omniagent agents

# Codex, non-interactive, on the current repo
docker run --rm -e OPENAI_API_KEY -v "$PWD":/work -w /work \
  ghcr.io/codehawaii/omniagent codex exec "add a test for utils.parse()"

# Aider on a git repo
docker run --rm -e ANTHROPIC_API_KEY -v "$PWD":/work -w /work \
  ghcr.io/codehawaii/omniagent aider --yes-always
```

**Trust:** run an agent directly on **your own** repo (it needs network for the
model API). For **untrusted** code, wrap the agent call with omnidev's
`sandbox-run.sh` (above) and pass `--net`.

**Staying current:** the image always builds the latest agents; CI rebuilds
weekly. To upgrade + cut a new image: `gh workflow run publish.yml` (or push a
`v*` tag). Current resolved versions live in
[`omniagent/.versions`](https://github.com/CodeHawaii/omniagent/blob/main/.versions).

---

## Cheat sheet (for agents calling these images)

```text
# isolate-and-build an unknown repo
curl -fsSLO https://raw.githubusercontent.com/CodeHawaii/omnidev/main/sandbox-run.sh && chmod +x sandbox-run.sh
OMNIDEV_IMAGE=ghcr.io/codehawaii/omnidev:latest ./sandbox-run.sh <repo> '<build/test cmd>'

# one-off toolchain command (trusted)
docker run --rm -v "$PWD":/work -w /work ghcr.io/codehawaii/omnidev bash -lc '<cmd>'

# run a coding agent on the current repo
docker run --rm -e ANTHROPIC_API_KEY -v "$PWD":/work -w /work \
  ghcr.io/codehawaii/omniagent claude -p '<instruction>'
```

| Need | Image | Entry |
|------|-------|-------|
| Build/test arbitrary repo | `ghcr.io/codehawaii/omnidev` | `bash -lc '...'` or `sandbox-run.sh` |
| Claude Code | `ghcr.io/codehawaii/omniagent` | `claude` (`ANTHROPIC_API_KEY`) |
| OpenAI Codex | `ghcr.io/codehawaii/omniagent` | `codex` (`OPENAI_API_KEY`) |
| Aider / Goose / Crush | `ghcr.io/codehawaii/omniagent` | `aider` / `goose` / `crush` |

Both images are MIT-licensed; bundled agents keep their own licenses.
