#!/usr/bin/env bash
# Session-start version check for the devstride plugin.
#
# Contract (the invariants file, section R, holds the reasons):
#   - NEVER blocks a session and NEVER exits non-zero. Every network command runs under a hard
#     deadline (macOS has no `timeout`; perl's alarm is portable), and every failure records
#     itself and stays quiet. A hook that hangs or errors on every session start is worse than
#     no check.
#   - SILENT when current or unreachable. It speaks only when there is something for the user
#     to do — the token-minimal choice; doctor reports the last record either way.
#   - Reads the RUNNING version from the loaded copy ($CLAUDE_PLUGIN_ROOT), never from disk, and
#     identifies that install by installPath, never by a guessed id. Repository opt-in may
#     auto-update only a project/local install bound to THIS repository. User/managed installs
#     are shared state: a repository may report their exact manual command, never mutate them.
#   - Config comes from the REPOSITORY ROOT's .claude/ds-config.json (`plugin` block), not the
#     launch directory: updateCheck (true), autoUpdate (false when the block is absent; setup
#     writes true for safe project/local updates), pin (null).
#   - Session start is the ONLY moment an update may be applied (opt-in). A successful command is
#     not enough: `plugin list --json` must then show the requested version on disk.
#   - It also refreshes the repository's COPY of the status line, which no plugin update can
#     reach on its own. Only a file still carrying the shipped `ds-statusline: managed v<x.y.z>`
#     marker is ever replaced, the previous one is kept as .bak, and a repo without a status
#     line never gets one created here — that needs consent, which is setup's and doctor's job.
#   - Recipe for "newest release": skills/doctor/references/version-currency.md — TAGS not
#     GitHub Releases; strip the `devstride--v` prefix; compare with sort -V.
# DEVSTRIDE_PLUGIN_UPDATE_CHECK=0 disables only the plugin check; status-line refresh remains an
# independent repository opt-in. DEVSTRIDE_PLUGIN_REPO overrides the release-tag source.

command -v python3 >/dev/null 2>&1 || exit 0
cap() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # cap SECONDS cmd args... — a hard deadline

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$ROOT" ] || exit 0
STDIN_JSON=$(cat 2>/dev/null | head -c 4000)
CWD=$(printf '%s' "$STDIN_JSON" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: print("")' 2>/dev/null)
CWD="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
# The repository root, so a session launched from packages/web still finds the repo's config.
REPO=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null); REPO="${REPO:-$CWD}"

read -r CHECK AUTO SLAUTO PIN <<EOF
$(python3 -c 'import json,sys
d={}
try: d=json.load(open(sys.argv[1]+"/.claude/ds-config.json"))
except Exception: pass
p=d.get("plugin",{}) or {}; s=d.get("statusLine",{}) or {}
print("1" if p.get("updateCheck",True) else "0", "1" if p.get("autoUpdate",False) else "0",
      "1" if s.get("autoUpdate",True) else "0", p.get("pin") or "-")' "$REPO" 2>/dev/null || echo "1 0 1 -")
EOF

newer() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ] && [ "$1" != "$2" ]; } # newer A B: B > A

# --- the repository's status line -------------------------------------------
# `.claude/statusline.sh` is a COPY of the file this plugin ships, so a fix to it
# reaches nobody who already has one unless something refreshes it. That is this, on the same
# session-start pass as the version check — and it is a local file compare, no network.
#
# Replaced ONLY while it still carries the shipped marker; deleting that line is how an owner
# takes the file over for good. The previous copy is kept as .bak so even a clobbered edit is
# recoverable, and this never CREATES a status line: a repo without one has not asked for one.
SL_RESULT="n/a"
SL_REPO="$REPO/.claude/statusline.sh"; SL_SHIPPED="$ROOT/skills/setup/references/statusline.sh"
if [ "$SLAUTO" = "1" ] && { [ -e "$SL_REPO" ] || [ -L "$SL_REPO" ]; } \
   && { [ -e "$SL_SHIPPED" ] || [ -L "$SL_SHIPPED" ]; }; then
  SL_RESULT=$(python3 - "$SL_REPO" "$SL_SHIPPED" <<'PY' 2>/dev/null || echo update-failed
import hashlib, os, re, secrets, stat, sys

target, source = sys.argv[1:]
limit = 1024 * 1024

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_nlink)

def safe_parent(path, label):
    parent = os.path.dirname(path)
    before = os.lstat(parent)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise ValueError(label + " parent is not a real directory")
    if before.st_uid != os.geteuid():
        raise ValueError(label + " parent has another owner")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(parent, flags)
    if identity(before) != identity(os.fstat(descriptor)):
        os.close(descriptor); raise ValueError(label + " parent changed while opening")
    return descriptor

def safe_read(path, label):
    before = os.lstat(path)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ValueError(label + " is not a regular non-symlink file")
    if before.st_uid != os.geteuid() or before.st_nlink != 1:
        raise ValueError(label + " must be owner-owned with one hard link")
    if before.st_size > limit:
        raise ValueError(label + " is unexpectedly large")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(descriptor)
    if identity(before) != identity(opened):
        os.close(descriptor); raise ValueError(label + " changed while opening")
    with os.fdopen(descriptor, "rb") as handle:
        data = handle.read(limit + 1); after = os.fstat(handle.fileno())
    if len(data) > limit or identity(opened) != identity(after):
        raise ValueError(label + " changed or exceeded its read limit")
    return data, before

def safe_read_at(directory_fd, name, label):
    before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ValueError(label + " is not a regular non-symlink file")
    if before.st_uid != os.geteuid() or before.st_nlink != 1 or before.st_size > limit:
        raise ValueError(label + " is unsafe or unexpectedly large")
    descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
    opened = os.fstat(descriptor)
    if identity(before) != identity(opened):
        os.close(descriptor); raise ValueError(label + " changed while opening")
    with os.fdopen(descriptor, "rb") as handle:
        data = handle.read(limit + 1); after = os.fstat(handle.fileno())
    if len(data) > limit or identity(opened) != identity(after):
        raise ValueError(label + " changed or exceeded its read limit")
    return data, after

def marker(data):
    match = re.search(rb"^# ds-statusline: managed v([0-9]+(?:\.[0-9]+)*) .*$", data, re.M)
    return match.group(1).decode() if match else ""

def temp_write(directory_fd, stem, data, mode):
    for _ in range(32):
        name = "." + stem + "." + secrets.token_hex(8)
        try:
            descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                 getattr(os, "O_NOFOLLOW", 0), mode, dir_fd=directory_fd)
            break
        except FileExistsError:
            continue
    else:
        raise OSError("could not allocate temporary status-line file")
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1; handle.write(data); handle.flush(); os.fsync(handle.fileno())
        return name
    finally:
        if descriptor >= 0: os.close(descriptor)

try:
    target_data, target_stat = safe_read(target, "repository status line")
    source_data, source_stat = safe_read(source, "shipped status line")
    have, want = marker(target_data), marker(source_data)
    if not have:
        print("owner-managed")
    elif not want or tuple(map(int, want.split("."))) <= tuple(map(int, have.split("."))):
        print("current")
    else:
        parent_fd = safe_parent(target, "repository status line")
        backup = os.path.basename(target) + ".bak"
        backup_temp = target_temp = ""
        try:
            bound_data, bound_stat = safe_read_at(
                parent_fd, os.path.basename(target), "repository status line"
            )
            if bound_data != target_data or identity(bound_stat) != identity(target_stat):
                raise ValueError("repository status line changed before refresh")
            if os.path.lexists(os.path.join(os.path.dirname(target), backup)):
                backup_path = os.path.join(os.path.dirname(target), backup)
                safe_read(backup_path, "status-line backup")
            backup_temp = temp_write(parent_fd, backup, target_data, stat.S_IMODE(target_stat.st_mode))
            os.replace(backup_temp, backup, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
            backup_temp = ""
            os.fsync(parent_fd)
            target_temp = temp_write(
                parent_fd, os.path.basename(target), source_data,
                stat.S_IMODE(source_stat.st_mode) | 0o111
            )
            final_data, final_stat = safe_read_at(
                parent_fd, os.path.basename(target), "repository status line"
            )
            if final_data != target_data or identity(final_stat) != identity(target_stat):
                raise ValueError("repository status line changed while preparing refresh")
            os.replace(target_temp, os.path.basename(target),
                       src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
            target_temp = ""
            os.fsync(parent_fd)
        finally:
            for temporary in (backup_temp, target_temp):
                if temporary:
                    try: os.unlink(temporary, dir_fd=parent_fd)
                    except FileNotFoundError: pass
            os.close(parent_fd)
        print("updated:" + have + ":" + want)
except Exception:
    print("update-refused")
PY
)
  case "$SL_RESULT" in
    updated:*)
      SL_HAVE=$(printf '%s' "$SL_RESULT" | cut -d: -f2); SL_WANT=$(printf '%s' "$SL_RESULT" | cut -d: -f3)
      echo "devstride status line: updated $SL_HAVE → $SL_WANT (.claude/statusline.sh; previous kept as .bak). Live now — no restart needed. Commit it so every clone gets it."
      ;;
  esac
fi

# Plugin checks and copied-status-line refreshes have separate opt-outs. In particular, a repo
# that pins or disables plugin updates can still receive a safe fix to its managed status line.
[ "${DEVSTRIDE_PLUGIN_UPDATE_CHECK:-1}" = "0" ] && exit 0
[ "$CHECK" = "0" ] && exit 0

RUNNING=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]+"/.claude-plugin/plugin.json")).get("version",""))
except Exception: print("")' "$ROOT" 2>/dev/null)
[ -n "$RUNNING" ] || exit 0

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/devstride-plugin"; mkdir -p "$CACHE_DIR" 2>/dev/null
NEWEST_CACHE="$CACHE_DIR/newest.json"                       # shared: the newest tag is not per-repo
KEY=$(printf '%s' "$REPO" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:12])')
RECORD="$CACHE_DIR/repo-$KEY.json"                            # per-repo: mode and result are
NOW=$(date +%s); TTL=21600                                    # 6h — a release is rare; a session start is not

NEWEST=""; SOURCE="cache"
if [ -f "$NEWEST_CACHE" ]; then
  read -r FETCHED_AT CACHED <<EOF
$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1])); print(d.get("fetchedAt",0), d.get("newest",""))
except Exception: print("0", "")' "$NEWEST_CACHE" 2>/dev/null || echo "0 ")
EOF
  [ -n "$CACHED" ] && [ $((NOW - ${FETCHED_AT:-0})) -lt $TTL ] && NEWEST="$CACHED"
fi
if [ -z "$NEWEST" ]; then
  SOURCE="network"
  NEWEST=$(cap 5 git ls-remote --tags "${DEVSTRIDE_PLUGIN_REPO:-https://github.com/devstride/claude-plugin}" 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/tags/||' | grep -v '\^{}' | sed 's/.*--v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  [ -n "$NEWEST" ] && python3 -c 'import json,sys,time; json.dump({"newest":sys.argv[2],"fetchedAt":int(time.time())},open(sys.argv[1],"w"))' "$NEWEST_CACHE" "$NEWEST" 2>/dev/null
fi

PREV_NOTIFIED=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("notifiedFor",""))
except Exception: print("")' "$RECORD" 2>/dev/null)
MODE="notify"; [ "$AUTO" = "1" ] && MODE="auto-update"; [ "$PIN" != "-" ] && MODE="pinned"
RESULT=""; NOTIFIED=""
finish() { # writes the per-repo record once, then exits 0 — the single exit path after the checks
  python3 -c 'import json,sys,time
json.dump({"checkedAt":int(time.time()),"repo":sys.argv[2],"running":sys.argv[3],"newest":sys.argv[4] or None,
           "source":sys.argv[5],"mode":sys.argv[6],"result":sys.argv[7],"install":sys.argv[8] or None,
           "notifiedFor":sys.argv[9],"statusLine":sys.argv[10]},open(sys.argv[1],"w"))' \
    "$RECORD" "$REPO" "$RUNNING" "$NEWEST" "$SOURCE" "$MODE" "$RESULT" "${INSTALL:-}" "$NOTIFIED" "${SL_RESULT:-n/a}" 2>/dev/null
  exit 0
}
[ -z "$NEWEST" ] && { RESULT="unreachable"; finish; }          # offline: quiet; doctor shows it

if [ "$PIN" != "-" ]; then
  # A pin is a VERSION, compared, not a flag. Each distinct situation is said ONCE, not every start.
  if [ "$RUNNING" != "$PIN" ]; then
    RESULT="pin-drift"; NOTIFIED="drift:$PIN:$RUNNING"
    [ "$PREV_NOTIFIED" != "$NOTIFIED" ] && echo "devstride plugin: this repository pins $PIN, but this session runs $RUNNING."
  elif newer "$RUNNING" "$NEWEST"; then
    RESULT="behind-pinned"; NOTIFIED="pinned:$PIN:$NEWEST"
    [ "$PREV_NOTIFIED" != "$NOTIFIED" ] && echo "devstride plugin: pinned at $PIN (running it); newest release is $NEWEST."
  else
    RESULT="current"
  fi
  finish
fi

newer "$RUNNING" "$NEWEST" || { RESULT="current"; finish; }   # current: silent

# Behind. Identify THIS install — an enabled row whose installPath is the loaded copy. Prefer a
# project/local row explicitly bound to this repository. Never infer that binding when the CLI
# omits projectPath: that row can be named for a manual repair, but repository config cannot apply
# an update through it.
INSTALL=$(cap 10 claude plugin list --json 2>/dev/null | python3 -c 'import json,os,sys
root=os.path.realpath(sys.argv[1]); repo=os.path.realpath(sys.argv[2]); rows=[]
try:
  for e in json.load(sys.stdin):
    if not e.get("enabled",True): continue
    if os.path.realpath(e.get("installPath","")) != root: continue
    rows.append(e)
except Exception: rows=[]
bound=[e for e in rows if e.get("scope") in ("project","local") and os.path.realpath(e.get("projectPath","") or "/nonexistent")==repo]
shared=[e for e in rows if e.get("scope") in ("user","managed")]
pick=(bound or shared or rows)
if pick:
  e=pick[0]; print(e["id"], e.get("scope","user"), "1" if e in bound else "0")
else: print("")' "$ROOT" "$REPO" 2>/dev/null)

if [ -z "$INSTALL" ]; then
  RESULT="lookup-failed"
  echo "devstride plugin: $RUNNING running, $NEWEST available. Could not identify this install from \`claude plugin list\` — run it to find the id and scope, then: claude plugin marketplace update devstride && claude plugin update <id> --scope <scope>, and restart."
  finish
fi
read -r ID SCOPE REPO_BOUND <<EOF
$INSTALL
EOF
INSTALL="$ID $SCOPE" # keep the doctor-facing record stable; the binding bit is internal only

if [ "$AUTO" = "1" ]; then
  if [ "$SCOPE" = "user" ] || [ "$SCOPE" = "managed" ]; then
    RESULT="shared-scope-auto-refused"; NOTIFIED="shared:$ID:$SCOPE:$RUNNING:$NEWEST"
    if [ "$PREV_NOTIFIED" != "$NOTIFIED" ]; then
      if [ "$SCOPE" = "managed" ]; then
        echo "devstride plugin: $RUNNING running, $NEWEST available. Repository auto-update cannot change the shared managed install $ID. Ask its administrator to run: claude plugin marketplace update devstride && claude plugin update $ID --scope managed, then restart."
      else
        echo "devstride plugin: $RUNNING running, $NEWEST available. Repository auto-update did not change the shared $SCOPE install $ID. To update it for every repository, run: claude plugin marketplace update devstride && claude plugin update $ID --scope $SCOPE, then restart."
      fi
    fi
    finish
  fi
  if [ "$REPO_BOUND" != "1" ] || { [ "$SCOPE" != "project" ] && [ "$SCOPE" != "local" ]; }; then
    RESULT="scope-binding-unverified"; NOTIFIED="unbound:$ID:$SCOPE:$RUNNING:$NEWEST"
    [ "$PREV_NOTIFIED" != "$NOTIFIED" ] && echo "devstride plugin: $RUNNING running, $NEWEST available. Repository auto-update did not run because \`claude plugin list\` could not prove $ID ($SCOPE) belongs to $REPO. Update it deliberately: claude plugin marketplace update devstride && claude plugin update $ID --scope $SCOPE, then restart."
    finish
  fi

  if cap 15 claude plugin marketplace update devstride >/dev/null 2>&1 && cap 45 claude plugin update "$ID" --scope "$SCOPE" --yes >/dev/null 2>&1; then
    # The loaded ROOT intentionally remains old until restart. Verify the selected install row by
    # id, scope and repository binding, not by the stale loaded installPath.
    INSTALLED=$(cap 10 claude plugin list --json 2>/dev/null | python3 -c 'import json,os,sys
pid,scope,repo=sys.argv[1],sys.argv[2],os.path.realpath(sys.argv[3]); found=""
try:
  for e in json.load(sys.stdin):
    if e.get("id") != pid or e.get("scope") != scope or not e.get("enabled",True): continue
    if scope in ("project","local") and os.path.realpath(e.get("projectPath","") or "/nonexistent") != repo: continue
    found=e.get("version",""); break
except Exception: pass
print(found)' "$ID" "$SCOPE" "$REPO" 2>/dev/null)
    if [ "$INSTALLED" = "$NEWEST" ] || { [ -n "$INSTALLED" ] && newer "$NEWEST" "$INSTALLED"; }; then
      RESULT="updated"
      echo "devstride plugin: updated on disk $RUNNING → $INSTALLED ($ID, $SCOPE). This session still runs $RUNNING — restart to pick it up."
      finish
    fi
    RESULT="update-verification-failed"
    echo "devstride plugin: the update command finished, but $ID ($SCOPE) still reports ${INSTALLED:-no installed version}; expected $NEWEST. This session still runs $RUNNING. Retry: claude plugin marketplace update devstride && claude plugin update $ID --scope $SCOPE, verify with claude plugin list, then restart."
    finish
  fi
  RESULT="update-failed"
  echo "devstride plugin: automatic update to $NEWEST failed (this session runs $RUNNING). By hand: claude plugin marketplace update devstride && claude plugin update $ID --scope $SCOPE, then restart."
  finish
fi

RESULT="behind"
echo "devstride plugin: $RUNNING running, $NEWEST available. To update (both commands, then restart):"
echo "  claude plugin marketplace update devstride && claude plugin update $ID --scope $SCOPE"
finish
