# omnidev

[![publish](https://github.com/CodeHawaii/omnidev/actions/workflows/publish.yml/badge.svg)](https://github.com/CodeHawaii/omnidev/actions/workflows/publish.yml)
[![GHCR](https://img.shields.io/badge/ghcr.io-codehawaii%2Fomnidev-2496ED?logo=docker&logoColor=white)](https://github.com/CodeHawaii/omnidev/pkgs/container/omnidev)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](./LICENSE)

A **universal, public, multi-language clone/build/test sandbox image**. Spin it up,
build or analyze an arbitrary repository inside it (isolated from your host), read
the results back out, throw the container away.

One image covers **Python (+uv) · Go · Node (+pnpm/yarn) · C/C++** plus `git`,
`ssh` and a lean CLI toolset — so you don't maintain a different image per stack.

```
docker pull ghcr.io/codehawaii/omnidev:latest
```

- **Multi-arch:** `linux/amd64`, `linux/arm64`
- **Base:** `debian:trixie-slim` — glibc, so manylinux Python wheels and cgo just work (no Alpine/musl pain)
- **User:** non-root `dev` (uid/gid `1000`) by default; toolchains live in `/usr/local`
- **PID 1:** `tini`, for correct signal handling and zombie reaping

---

## What's inside

| Tool | Version | Notes |
|------|---------|-------|
| Debian | 13 (trixie) | glibc base, slim |
| Python | 3.13.x | `python3` + `pip` + `venv` (system env is PEP 668 "externally managed" — use a venv or uv) |
| uv | 0.11.21 | `uv` + `uvx`, from the official image; can manage its own Python versions too |
| Go | 1.26.4 | official tarball at `/usr/local/go` |
| Node.js | 24.16.0 LTS | official tarball at `/usr/local/node` |
| pnpm / yarn | via corepack | activated shims; `npm` is Node's bundled one |
| C/C++ | gcc/g++ 14 | `build-essential`, `make`, `cmake`, `pkg-config`, autotools |
| C dev headers | — | `libssl` `zlib` `libffi` `libsqlite3` `libreadline` `libbz2` `liblzma` `libxml2` `libxslt1` |
| VCS / net | — | `git`, `git-lfs`, `openssh-client`, `gnupg`, `curl`, `wget`, `ca-certificates` |
| CLI | — | `jq`, `ripgrep` (`rg`), `fd`, `tree`, `unzip`, `zip`, `xz`, `file`, `patch`, `less`, `vim-tiny`, `nano` |

Deliberately **out of scope** to stay lean: headless Chromium/Puppeteer, DB client
headers (`libpq`, mysql), image libs (`libjpeg`/`png`/`webp`), `clang`/`lldb`/`valgrind`,
Docker-in-Docker. Add them in a downstream `FROM ghcr.io/codehawaii/omnidev` image if needed.

---

## Quick start

```bash
# Interactive shell
docker run --rm -it ghcr.io/codehawaii/omnidev bash

# One-off: build & test a cloned repo (you manage isolation yourself)
docker run --rm -v "$PWD":/work -w /work ghcr.io/codehawaii/omnidev \
  bash -lc 'uv sync && uv run pytest -q'
```

For **untrusted** code, don't hand-roll the flags — use `sandbox-run.sh` below.

---

## `sandbox-run.sh` — run untrusted repos safely

The whole point of this image: analyze a library you don't fully trust without
giving it your host. `sandbox-run.sh` copies the repo into a throwaway run dir,
runs your command in a hardened container, and leaves the logs + artifacts on disk.

```
   host repo (untrusted)                  omnidev container (hardened)
   ┌────────────────────┐    cp -a    ┌────────────────────────────────────┐
   │ ~/code/somelib     │ ─────────►  │  /work    ← repo copy, read-write   │
   └────────────────────┘             │  /results → artifacts you keep      │
            ▲                          │  rootfs   → read-only               │
            │  read results back       │  caps     → ALL dropped             │
            │                          │  net      → none (opt-in --net)     │
   ./omnidev-runs/<timestamp>/         │  user     → dev (uid 1000)          │
     ├─ work/       built tree         │  limits   → mem / cpus / pids       │
     ├─ out/        (= /results)       └────────────────────────────────────┘
     ├─ run.log     stdout+stderr
     └─ exit_code   container exit status
```

```bash
# Build/pull the image first, then:
export OMNIDEV_IMAGE=ghcr.io/codehawaii/omnidev:latest      # or omnidev:local

# Run a test suite with NO network (default):
./sandbox-run.sh ~/code/somelib 'uv sync --offline && uv run pytest -q'

# A build that needs to fetch deps — opt into a network explicitly:
./sandbox-run.sh --net ~/code/somelib 'go test ./...'

# Poke around interactively:
./sandbox-run.sh --shell ~/code/somelib
```

**Defaults** (all overridable): `--net none`, `--memory 4g`, `--cpus 2`,
`--pids 512`, `--read-only` rootfs with tmpfs `/tmp`, `/run`, `/home/dev`.
Run `./sandbox-run.sh --help` for the full flag list.

### Isolation is defense-in-depth, not a vault

A container shares the host kernel — it is **not** a hard boundary against a
determined attacker. This wrapper drops all capabilities, sets
`no-new-privileges`, keeps Docker's default seccomp profile, mounts the root
filesystem read-only, caps resources, and runs with **no network** by default.
For a stronger boundary, set `OMNIDEV_RUNTIME=runsc` (gVisor) or run inside a
microVM (Firecracker). Remember that `--net` lets install/postinstall hooks
reach the network.

---

## Environment

| Var | Value | Why |
|-----|-------|-----|
| `LANG`/`LC_ALL` | `C.UTF-8` | UTF-8 everywhere; `en_US.UTF-8` is also generated |
| `GOPATH` | `/home/dev/go` | on the writable home |
| `GOTOOLCHAIN` | `local` | never auto-downloads a different Go; override with `-e GOTOOLCHAIN=auto` (needs network) for repos pinning a newer Go |
| `PNPM_HOME` | `/pnpm` | on `PATH`; `sandbox-run.sh` relocates it to the writable home |
| `COREPACK_HOME` | `/usr/local/corepack` | corepack cache; `sandbox-run.sh` relocates it to the writable home so `packageManager`-pinned repos work |
| `UV_CACHE_DIR` | `/home/dev/.cache/uv` | |
| `PYTHONUNBUFFERED` | `1` | immediate log flushing |

---

## Build & publish

```bash
make build     # host-arch image -> omnidev:local
make smoke     # print every bundled tool version
make sandbox   # demo: run a command against this repo in the sandbox
make run       # build + interactive shell
```

CI runs in two workflows:
- **`.github/workflows/publish.yml`** — builds **multi-arch** and pushes to GHCR on
  push to `main` (`:edge`, `:latest`, `:sha`), a `v*` tag (semver tags), or manual
  dispatch, with **SLSA provenance + SPDX SBOM** attestations.
- **`.github/workflows/pr-build.yml`** — on pull requests (and manual dispatch),
  builds amd64 and runs the toolchain smoke test only (no push).

### One-time: make the GHCR package public

GHCR packages start **private**. After the first successful publish, on GitHub:
**Org → Packages → `omnidev` → Package settings → Change visibility → Public**.

> ⚠️ Public visibility is effectively irreversible and there is no API toggle —
> do it once, deliberately. Once public, anyone can `docker pull` with no login.

---

## License

MIT — see [LICENSE](./LICENSE).
