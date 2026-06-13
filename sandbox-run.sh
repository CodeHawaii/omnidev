#!/usr/bin/env bash
# sandbox-run.sh — run an UNTRUSTED repo's build/test command inside the omnidev
# image with defense-in-depth isolation, then collect logs + artifacts on the host.
#
# Usage:
#   sandbox-run.sh [options] <repo-path> <command...>
#   sandbox-run.sh --shell  [options] <repo-path>      # interactive poke-around shell
#
# The repo at <repo-path> is COPIED into a fresh run dir, so your original source
# is never mutated by the code running inside. The copy is mounted read-write at
# /work (the working dir). Anything you want to keep, write to /results. The
# container's stdout+stderr go to <run>/run.log and its exit code to <run>/exit_code.
#
# Options (defaults in []):
#   --net[=MODE]    enable networking [none]; bare --net means a bridge network
#   --image NAME    image to run [$OMNIDEV_IMAGE or omnidev:local]
#   --memory SIZE   memory cap [4g]
#   --cpus N        cpu cap [2]
#   --pids N        pids cap [512]
#   --tmp-size SIZE /tmp tmpfs size [2g]
#   --home-size SIZE  /home/dev tmpfs size [4g]
#   --out DIR       run dir [./omnidev-runs/<timestamp>]
#   --shell         drop into an interactive shell instead of running a command
#   -h, --help      show this header
#
# Security note: a container is NOT a hard boundary against a determined attacker
# (shared kernel). This wrapper drops ALL capabilities, blocks new privileges,
# keeps Docker's default seccomp profile, mounts the rootfs read-only, caps
# resources, and defaults to NO network. For a stronger boundary set
# OMNIDEV_RUNTIME=runsc (gVisor) or run inside a microVM. Passing --net lets
# untrusted install/postinstall hooks reach the network — use it deliberately.
set -euo pipefail

IMAGE="${OMNIDEV_IMAGE:-omnidev:local}"
RUNTIME="${OMNIDEV_RUNTIME:-}"
NET="none"
MEM="4g"
CPUS="2"
PIDS="512"
TMP_SIZE="2g"
HOME_SIZE="4g"
OUT=""
SHELL_MODE="0"

die()  { echo "sandbox-run: $*" >&2; exit 2; }
need() { [ "$#" -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --net)        NET="bridge"; shift ;;
    --net=*)      NET="${1#*=}"; shift ;;
    --image)      need "$@"; IMAGE="$2"; shift 2 ;;
    --memory)     need "$@"; MEM="$2"; shift 2 ;;
    --cpus)       need "$@"; CPUS="$2"; shift 2 ;;
    --pids)       need "$@"; PIDS="$2"; shift 2 ;;
    --tmp-size)   need "$@"; TMP_SIZE="$2"; shift 2 ;;
    --home-size)  need "$@"; HOME_SIZE="$2"; shift 2 ;;
    --out)        need "$@"; OUT="$2"; shift 2 ;;
    --shell)      SHELL_MODE="1"; shift ;;
    -h|--help)    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    --)           shift; break ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)            break ;;
  esac
done

command -v docker >/dev/null || die "docker not found on PATH"
[ $# -ge 1 ] || die "missing <repo-path> (try --help)"
REPO="$1"; shift
[ -d "$REPO" ] || die "repo path not found: $REPO"
REPO_ABS="$(cd "$REPO" && pwd)"

if [ "$SHELL_MODE" = "0" ] && [ $# -lt 1 ]; then
  die "missing <command> — pass a command, or use --shell for an interactive shell"
fi

TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${OUT:-$(pwd)/omnidev-runs/$TS}"
mkdir -p "$RUN_DIR/work" "$RUN_DIR/out"

echo "sandbox-run: copying $REPO_ABS -> $RUN_DIR/work" >&2
cp -a "$REPO_ABS/." "$RUN_DIR/work/"

# Hardened `docker run` arguments (defense in depth).
args=(
  run --rm
  --user 1000:1000
  --network "$NET"
  --read-only
  --tmpfs /tmp:rw,nosuid,nodev,size="$TMP_SIZE"
  --tmpfs /run:rw,nosuid,nodev,size=64m
  --tmpfs /home/dev:rw,nosuid,nodev,uid=1000,gid=1000,size="$HOME_SIZE"
  --cap-drop ALL
  --security-opt no-new-privileges
  --pids-limit "$PIDS"
  --memory "$MEM" --memory-swap "$MEM"
  --cpus "$CPUS"
  -e HOME=/home/dev
  -e PNPM_HOME=/home/dev/.pnpm
  -e COREPACK_HOME=/home/dev/.corepack
  -v "$RUN_DIR/work":/work:rw
  -v "$RUN_DIR/out":/results:rw
  -w /work
)
[ -n "$RUNTIME" ] && args+=(--runtime "$RUNTIME")

if [ "$SHELL_MODE" = "1" ]; then
  echo "sandbox-run: interactive shell (network=$NET). Source copy at /work, keep outputs in /results." >&2
  exec docker "${args[@]}" -it "$IMAGE" bash
fi

CMD="$*"
echo "sandbox-run: running (network=$NET mem=$MEM cpus=$CPUS pids=$PIDS): $CMD" >&2
set +e
docker "${args[@]}" "$IMAGE" bash -lc "$CMD" 2>&1 | tee "$RUN_DIR/run.log"
code="${PIPESTATUS[0]}"
set -e
echo "$code" > "$RUN_DIR/exit_code"
echo "sandbox-run: exit=$code  log=$RUN_DIR/run.log  artifacts=$RUN_DIR/out  worktree=$RUN_DIR/work" >&2
exit "$code"
