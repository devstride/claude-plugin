#!/usr/bin/env bash
# Session-start version check for the devstride plugin.
#
# Contract (the invariants file, section R, holds the reasons):
#   - NEVER blocks a session and NEVER exits non-zero. Every network command runs under a hard
#     deadline (macOS has no `timeout`); timed-out process groups are killed, and every failure records
#     itself and stays quiet. A hook that hangs or errors on every session start is worse than
#     no check.
#   - SILENT when current or unreachable. It speaks only when there is something for the user
#     to do — the token-minimal choice; doctor reports the last record either way.
#   - Reads the RUNNING version from the loaded copy ($CLAUDE_PLUGIN_ROOT), never from disk, and
#     identifies that install by installPath, never by a guessed id. Repository opt-in may
#     auto-update only a project/local install bound to THIS repository. Shared user installs hand
#     off to `/devstride:update`; managed installs stay with their administrator.
#   - Config comes from the REPOSITORY ROOT's .claude/ds-config.json (`plugin` block), not the
#     launch directory: updateCheck (true), autoUpdate (false when the block is absent; setup
#     writes true for safe project/local updates), pin (null).
#   - Repository-configured AUTOMATIC updates run only at session start. A direct
#     `/devstride:update` is separate user authority and stops for reload after changing disk.
#     A successful command or matching version is not enough: the canonical tag and installed
#     payload must match before reload is allowed.
#   - It also refreshes the repository's COPY of the status line, which no plugin update can
#     reach on its own. Only a file still carrying the shipped `ds-statusline: managed v<x.y.z>`
#     marker is ever replaced, the previous one is kept as .bak, and a repo without a status
#     line never gets one created here — that needs consent, which is setup's and doctor's job.
#   - Recipe for "newest release": skills/doctor/references/version-currency.md — TAGS not
#     GitHub Releases; accept only the exact `devstride--v<semver>` prefix; compare numerically.
# DEVSTRIDE_PLUGIN_UPDATE_CHECK=0 disables only the plugin check; status-line refresh remains an
# independent repository opt-in. Release tags always come from the canonical public repository.

command -v python3 >/dev/null 2>&1 || exit 0

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$ROOT" ] || exit 0
UPDATE_HELPER="$ROOT/skills/update/scripts/update-plugin.py"
LATEST_HELPER="$ROOT/skills/update/scripts/latest-version.sh"
STDIN_JSON=$(cat 2>/dev/null | head -c 4000)
CWD=$(printf '%s' "$STDIN_JSON" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: print("")' 2>/dev/null)
CWD="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
# The repository root, so a session launched from packages/web still finds the repo's config.
REPO=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null); REPO="${REPO:-$CWD}"

read -r CHECK AUTO SLAUTO PIN CONFIG_VALID <<EOF
$(python3 -c 'import json,os,re,stat,sys
path=os.path.join(sys.argv[1],".claude","ds-config.json"); valid=True
if os.path.lexists(path):
  try:
    fd=os.open(path,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW); info=os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in (os.getuid(),0) or info.st_nlink!=1 or info.st_size>1048576: raise ValueError()
    raw=b""
    while len(raw)<=1048576:
      chunk=os.read(fd,min(65536,1048577-len(raw)))
      if not chunk: break
      raw+=chunk
    os.close(fd)
    if len(raw)>1048576: raise ValueError()
    d=json.loads(raw)
  except Exception:
    try: os.close(fd)
    except Exception: pass
    d={}; valid=False
else: d={}
if not isinstance(d,dict): d={}; valid=False
p=d.get("plugin",{}); s=d.get("statusLine",{})
if not isinstance(p,dict): p={}; valid=False
if not isinstance(s,dict): s={}; valid=False
def flag(obj,key,default):
  global valid
  if key not in obj: return default
  if type(obj[key]) is not bool: valid=False; return False
  return obj[key]
pin=p.get("pin")
if pin is not None and (not isinstance(pin,str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",pin)):
  valid=False; pin=None
print("1" if flag(p,"updateCheck",True) else "0", "1" if flag(p,"autoUpdate",False) else "0",
      "1" if flag(s,"autoUpdate",True) else "0", pin or "-", "1" if valid else "0")' "$REPO" 2>/dev/null || echo "0 0 0 - 0")
EOF
[ "$CONFIG_VALID" = "1" ] || { CHECK=1; AUTO=0; SLAUTO=0; PIN="-"; }

newer() { python3 -c 'import sys
try: a,b=(tuple(map(int,v.split("."))) for v in sys.argv[1:]); raise SystemExit(0 if b>a else 1)
except Exception: raise SystemExit(1)' "$1" "$2"; } # newer A B: B > A

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
  SL_RESULT=$(python3 - "$SL_REPO" "$SL_SHIPPED" <<'PY' 2>/dev/null || echo update-refused
import fcntl, hashlib, os, re, secrets, stat, sys

target, source = sys.argv[1:]
limit = 1024 * 1024

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_nlink)

def moved_identity(value):
    # A same-directory rename changes ctime on macOS. Everything else still identifies the
    # exact file we inspected, including its inode, contents-relevant metadata, and link count.
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_size, value.st_mtime_ns, value.st_nlink)

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

def link_no_replace(directory_fd, source_name, destination_name):
    # Unlike os.replace, link(2) fails when a last-second writer already owns the destination.
    os.link(source_name, destination_name, src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd, follow_symlinks=False)

def restore_no_replace(directory_fd, held_name, destination_name):
    try:
        link_no_replace(directory_fd, held_name, destination_name)
    except FileExistsError:
        return False
    os.unlink(held_name, dir_fd=directory_fd)
    return True

def move_into_hold(directory_fd, source_name, stem):
    held_name = temp_write(directory_fd, stem, b"", 0o600)
    try:
        os.replace(source_name, held_name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    except Exception:
        os.unlink(held_name, dir_fd=directory_fd)
        raise
    return held_name

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
        fcntl.flock(parent_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        target_name = os.path.basename(target)
        backup = target_name + ".bak"
        backup_hold = target_hold = target_temp = ""
        backup_hold_expected = target_hold_expected = backup_committed = False
        try:
            bound_data, bound_stat = safe_read_at(
                parent_fd, target_name, "repository status line"
            )
            if bound_data != target_data or identity(bound_stat) != identity(target_stat):
                raise ValueError("repository status line changed before refresh")

            backup_data = backup_stat = None
            try:
                backup_data, backup_stat = safe_read_at(parent_fd, backup, "status-line backup")
            except FileNotFoundError:
                pass

            target_temp = temp_write(
                parent_fd, target_name, source_data,
                stat.S_IMODE(source_stat.st_mode) | 0o111
            )

            # Move a prior backup aside without destroying it. If its path changed after our
            # inspection, the moved file fails the identity check and is restored without
            # overwriting whatever another writer put there.
            if backup_stat is not None:
                backup_hold = move_into_hold(parent_fd, backup, backup + ".hold")
                moved_data, moved_stat = safe_read_at(parent_fd, backup_hold, "status-line backup")
                if moved_data != backup_data or moved_identity(moved_stat) != moved_identity(backup_stat):
                    if restore_no_replace(parent_fd, backup_hold, backup):
                        backup_hold = ""
                    raise ValueError("status-line backup changed before refresh")
                backup_hold_expected = True

            # First take the exact inspected target out of the destination path. From here on,
            # no-overwrite links mean a writer that lands in either final gap always wins.
            target_hold = move_into_hold(parent_fd, target_name, target_name + ".hold")
            held_data, held_stat = safe_read_at(parent_fd, target_hold, "repository status line")
            if held_data != target_data or moved_identity(held_stat) != moved_identity(target_stat):
                if restore_no_replace(parent_fd, target_hold, target_name):
                    target_hold = ""
                raise ValueError("repository status line changed while preparing refresh")
            target_hold_expected = True

            link_no_replace(parent_fd, target_hold, backup)
            backup_committed = True
            os.fsync(parent_fd)
            link_no_replace(parent_fd, target_temp, target_name)
            os.unlink(target_temp, dir_fd=parent_fd)
            target_temp = ""
            committed_data, committed_stat = safe_read_at(
                parent_fd, target_name, "refreshed repository status line"
            )
            if committed_data != source_data or not committed_stat.st_mode & 0o111:
                raise ValueError("repository status line changed while committing refresh")
            os.unlink(target_hold, dir_fd=parent_fd)
            target_hold = ""
            if backup_hold:
                os.unlink(backup_hold, dir_fd=parent_fd)
                backup_hold = ""
            os.fsync(parent_fd)
        except Exception:
            if target_hold:
                if target_hold_expected and backup_committed:
                    os.unlink(target_hold, dir_fd=parent_fd)
                    target_hold = ""
                elif restore_no_replace(parent_fd, target_hold, target_name):
                    target_hold = ""
                elif target_hold_expected:
                    try:
                        link_no_replace(parent_fd, target_hold, backup)
                        os.unlink(target_hold, dir_fd=parent_fd)
                        target_hold = ""
                    except FileExistsError:
                        pass
            if backup_hold:
                if restore_no_replace(parent_fd, backup_hold, backup):
                    backup_hold = ""
                elif backup_hold_expected:
                    # Another writer now owns .bak; the superseded plugin backup can retire.
                    os.unlink(backup_hold, dir_fd=parent_fd)
                    backup_hold = ""
            os.fsync(parent_fd)
            raise
        finally:
            for temporary in (target_temp,):
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
[ "$CHECK" = "0" ] && [ "$CONFIG_VALID" = "1" ] && exit 0

read -r RUNNING RUNTIME_VALID <<EOF
$(python3 -c 'import json,os,re,stat,sys
path=os.path.join(os.path.realpath(sys.argv[1]),".claude-plugin","plugin.json")
try:
  fd=os.open(path,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW); info=os.fstat(fd)
  if not stat.S_ISREG(info.st_mode) or info.st_uid not in (os.getuid(),0) or info.st_nlink!=1 or info.st_size>1048576: raise ValueError()
  data=os.read(fd,1048577); os.close(fd); manifest=json.loads(data); version=manifest.get("version")
  if manifest.get("name")!="devstride" or not isinstance(version,str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",version): raise ValueError()
  print(version,"1")
except Exception:
  try: os.close(fd)
  except Exception: pass
  print("unknown","0")' "$ROOT" 2>/dev/null || echo "unknown 0")
EOF

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_DIR=$(python3 - "$CACHE_ROOT" <<'PY' 2>/dev/null
import os,stat,sys
root=os.path.realpath(sys.argv[1]); os.makedirs(root,mode=0o700,exist_ok=True)
root_info=os.lstat(root)
if not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid not in (os.getuid(),0): raise SystemExit(1)
root_fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
  try: os.mkdir("devstride-plugin",0o700,dir_fd=root_fd)
  except FileExistsError: pass
  info=os.stat("devstride-plugin",dir_fd=root_fd,follow_symlinks=False)
  if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid(): raise SystemExit(1)
  os.chmod("devstride-plugin",0o700,dir_fd=root_fd,follow_symlinks=False)
  print(os.path.join(root,"devstride-plugin"))
finally: os.close(root_fd)
PY
)
NEWEST_CACHE="${CACHE_DIR:+$CACHE_DIR/newest.json}"          # shared: newest tag is not per-repo
KEY=$(printf '%s' "$REPO" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:12])')
RECORD="${CACHE_DIR:+$CACHE_DIR/repo-$KEY.json}"              # per-repo: mode and result are
NOW=$(date +%s); TTL=21600                                    # 6h — a release is rare; a session start is not

state_write() { # atomic, owner-only, no symlink/hardlink following; races refuse instead of clobber
  [ -n "$1" ] || return 1
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json,os,secrets,stat,sys
path,payload=sys.argv[1],json.loads(sys.argv[2]); parent=os.path.realpath(os.path.dirname(path)); name=os.path.basename(path)
data=(json.dumps(payload,separators=(",",":"),sort_keys=True)+"\n").encode(); directory=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
temporary=".%s.%s.tmp"%(name,secrets.token_hex(8)); fd=None; original=None
try:
  try:
    original=os.stat(name,dir_fd=directory,follow_symlinks=False)
    if not stat.S_ISREG(original.st_mode) or original.st_uid!=os.getuid() or original.st_nlink!=1: raise ValueError()
  except FileNotFoundError: pass
  fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)
  os.write(fd,data); os.fsync(fd); os.close(fd); fd=None
  try: current=os.stat(name,dir_fd=directory,follow_symlinks=False)
  except FileNotFoundError: current=None
  identity=lambda s: None if s is None else (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns,s.st_mode,s.st_uid,s.st_nlink)
  if identity(current)!=identity(original): raise ValueError()
  os.replace(temporary,name,src_dir_fd=directory,dst_dir_fd=directory); temporary=""; os.fsync(directory)
finally:
  if fd is not None: os.close(fd)
  if temporary:
    try: os.unlink(temporary,dir_fd=directory)
    except FileNotFoundError: pass
  os.close(directory)
PY
}

if [ "$CONFIG_VALID" != "1" ]; then
  INVALID_PAYLOAD=$(python3 -c 'import json,sys,time
print(json.dumps({"checkedAt":int(time.time()),"repo":sys.argv[1],"running":sys.argv[2],"newest":None,
 "source":"cache","mode":"invalid","result":"invalid-config","install":None,
 "notifiedFor":"","statusLine":sys.argv[3]}))' "$REPO" "$RUNNING" "${SL_RESULT:-n/a}")
  state_write "$RECORD" "$INVALID_PAYLOAD" || true
  exit 0
fi
if [ "$RUNTIME_VALID" != "1" ]; then
  RUNTIME_PAYLOAD=$(python3 -c 'import json,sys,time
print(json.dumps({"checkedAt":int(time.time()),"repo":sys.argv[1],"running":None,"newest":None,
 "source":"cache","mode":"invalid","result":"invalid-runtime","install":None,
 "notifiedFor":"","statusLine":sys.argv[2]}))' "$REPO" "${SL_RESULT:-n/a}")
  state_write "$RECORD" "$RUNTIME_PAYLOAD" || true
  exit 0
fi

NEWEST=""; SOURCE="cache"
if [ -n "$NEWEST_CACHE" ]; then
  NEWEST=$(python3 - "$NEWEST_CACHE" "$NOW" "$TTL" <<'PY' 2>/dev/null
import json,os,re,stat,sys
path=sys.argv[1]
try:
  fd=os.open(path,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW); info=os.fstat(fd)
  if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or info.st_size>4096: raise ValueError()
  data=os.read(fd,4097); os.close(fd); value=json.loads(data)
  fetched=value.get("fetchedAt"); newest=value.get("newest"); now=int(sys.argv[2]); ttl=int(sys.argv[3])
  trusted=value.get("schema")==2 and value.get("source")=="https://github.com/devstride/claude-plugin"
  if trusted and type(fetched) is int and isinstance(newest,str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",newest) and 0<=now-fetched<ttl: print(newest)
except Exception:
  try: os.close(fd)
  except Exception: pass
PY
)
fi
if [ -z "$NEWEST" ]; then
  SOURCE="network"
  NEWEST=$(bash "$LATEST_HELPER" 2>/dev/null)
  if [ -n "$NEWEST" ]; then
    NEWEST_PAYLOAD=$(python3 -c 'import json,sys,time; print(json.dumps({"schema":2,"source":"https://github.com/devstride/claude-plugin","newest":sys.argv[1],"fetchedAt":int(time.time())}))' "$NEWEST")
    state_write "$NEWEST_CACHE" "$NEWEST_PAYLOAD" || true
  fi
fi

PREV_NOTIFIED=$(python3 - "$RECORD" <<'PY' 2>/dev/null
import json,os,stat,sys
try:
  fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW); info=os.fstat(fd)
  if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or info.st_size>16384: raise ValueError()
  data=os.read(fd,16385); os.close(fd); value=json.loads(data).get("notifiedFor","")
  if isinstance(value,str) and len(value)<=1024: print(value)
except Exception:
  try: os.close(fd)
  except Exception: pass
PY
)
MODE="notify"; [ "$AUTO" = "1" ] && MODE="auto-update"; [ "$PIN" != "-" ] && MODE="pinned"
RESULT=""; NOTIFIED=""
finish() { # writes the per-repo record once, then exits 0 — the single exit path after the checks
  RECORD_PAYLOAD=$(python3 -c 'import json,sys,time
print(json.dumps({"checkedAt":int(time.time()),"repo":sys.argv[1],"running":sys.argv[2],"newest":sys.argv[3] or None,
 "source":sys.argv[4],"mode":sys.argv[5],"result":sys.argv[6],"install":sys.argv[7] or None,
 "notifiedFor":sys.argv[8],"statusLine":sys.argv[9]}))' \
    "$REPO" "$RUNNING" "$NEWEST" "$SOURCE" "$MODE" "$RESULT" "${INSTALL:-}" "$NOTIFIED" "${SL_RESULT:-n/a}")
  state_write "$RECORD" "$RECORD_PAYLOAD" || true
  exit 0
}
[ -z "$NEWEST" ] && { RESULT="unreachable"; finish; }          # offline: quiet; doctor shows it

# A version beyond the newest signed-off tag is never "current," even when a repository pin
# happens to name it. The hook cannot prove where that code came from, so it must not bless it.
if newer "$NEWEST" "$RUNNING"; then
  if [ "$PIN" != "-" ]; then RESULT="pinned-ahead"; else RESULT="running-ahead"; fi
  echo "devstride plugin: this session runs $RUNNING, newer than the latest tagged release $NEWEST. Do not reload or update; run /devstride:doctor."
  finish
fi

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

if [ "$RUNNING" = "$NEWEST" ]; then RESULT="current"; finish; fi
newer "$RUNNING" "$NEWEST" || { RESULT="invalid-runtime"; finish; }

# Behind. Resolve the exact loaded row through the same alias/scope/cache-lineage rules used by
# `/devstride:update`; neither path guesses an id or mutates duplicate/unbound installs.
INSPECT=$(python3 "$UPDATE_HELPER" inspect --root "$ROOT" --repo "$REPO" 2>/dev/null)
INSTALL=$(printf '%s' "$INSPECT" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  if d.get("status") == "ok": print(d["id"], d["scope"], "1" if d.get("repoBound") else "0", d["diskVersion"])
except Exception: pass' 2>/dev/null)

if [ -z "$INSTALL" ]; then
  RESULT="lookup-failed"
  echo "devstride plugin: $RUNNING running, $NEWEST available, but the active install is ambiguous or unsafe. Run /devstride:doctor; do not guess an update id or scope."
  finish
fi
read -r ID SCOPE REPO_BOUND DISK_VERSION <<EOF
$INSTALL
EOF
INSTALL="$ID $SCOPE" # keep the doctor-facing record stable; the binding bit is internal only

if [ "$DISK_VERSION" = "$NEWEST" ] \
   && { [ "$AUTO" != "1" ] || { [ "$SCOPE" != "project" ] && [ "$SCOPE" != "local" ]; } \
        || [ "$REPO_BOUND" != "1" ]; }; then
  RESULT="disk-current-unverified"
  if [ "$SCOPE" = "managed" ]; then
    echo "devstride plugin: disk claims $DISK_VERSION, but this session still runs $RUNNING and the tagged files have not been verified. Ask its administrator to verify the install; do not reload it yet."
  else
    echo "devstride plugin: disk claims $DISK_VERSION, but this session still runs $RUNNING and the tagged files have not been verified. Run /devstride:update; do not reload this copy yet."
  fi
  finish
fi
if newer "$NEWEST" "$DISK_VERSION"; then
  RESULT="installed-ahead"
  echo "devstride plugin: disk reports $DISK_VERSION, newer than the latest tagged release $NEWEST. Run /devstride:update for the integrity check; do not reload this copy yet."
  finish
fi

if [ "$AUTO" = "1" ]; then
  if [ "$SCOPE" = "user" ] || [ "$SCOPE" = "managed" ]; then
    RESULT="shared-scope-auto-refused"; NOTIFIED="shared:$ID:$SCOPE:$RUNNING:$NEWEST"
    if [ "$PREV_NOTIFIED" != "$NOTIFIED" ]; then
      if [ "$SCOPE" = "managed" ]; then
        echo "devstride plugin: $RUNNING running, $NEWEST available. Repository auto-update cannot change managed install $ID. Its administrator must update and verify the tagged payload; then run /reload-plugins and confirm no DevStride load error, or restart."
      else
        echo "devstride plugin: $RUNNING running, $NEWEST available. Repository auto-update cannot change shared $SCOPE install $ID. Run /devstride:update to update and verify that exact install."
      fi
    fi
    finish
  fi
  if [ "$REPO_BOUND" != "1" ] || { [ "$SCOPE" != "project" ] && [ "$SCOPE" != "local" ]; }; then
    RESULT="scope-binding-unverified"; NOTIFIED="unbound:$ID:$SCOPE:$RUNNING:$NEWEST"
    [ "$PREV_NOTIFIED" != "$NOTIFIED" ] && echo "devstride plugin: $RUNNING running, $NEWEST available. Repository auto-update cannot prove $ID ($SCOPE) belongs to this repository. Run /devstride:doctor; do not guess the scope."
    finish
  fi

  # The explicit updater is also the single release/source/install verifier. The repository opt-in
  # above supplies background authority only for this bound project/local row.
  # The helper owns the total deadline so it can kill its active child process group before
  # releasing the lock. An outer shell timeout could orphan a still-mutating CLI child.
  APPLY=$(python3 "$UPDATE_HELPER" apply --root "$ROOT" --repo "$REPO" \
    --total-timeout 120 2>/dev/null)
  VERIFIED=$(printf '%s' "$APPLY" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); status=d.get("status")
  if status in ("updated","current") and d.get("safeToReload") is True and d.get("diskAfter") == d.get("targetVersion"):
    print(status,d["diskAfter"],d["targetVersion"],d["id"],d["scope"])
except Exception: pass' 2>/dev/null)
  if [ -n "$VERIFIED" ]; then
    read -r UPDATE_STATUS INSTALLED TARGET GOT_ID GOT_SCOPE <<EOF
$VERIFIED
EOF
    if [ "$GOT_ID" = "$ID" ] && [ "$GOT_SCOPE" = "$SCOPE" ] && newer "$RUNNING" "$TARGET"; then
      NEWEST="$TARGET"
      if [ "$UPDATE_STATUS" = "updated" ]; then
        RESULT="updated"
        echo "devstride plugin: updated on disk $RUNNING → $INSTALLED ($ID, $SCOPE). This session still runs $RUNNING — run /reload-plugins and confirm no DevStride load error; restart if reload fails."
      else
        RESULT="disk-current-verified"
        echo "devstride plugin: verified the $INSTALLED tagged copy already on disk ($ID, $SCOPE). This session still runs $RUNNING — run /reload-plugins and confirm no DevStride load error; restart if reload fails."
      fi
      finish
    fi
  fi
  APPLY_CODE=$(printf '%s' "$APPLY" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("code", ""))
except Exception: pass' 2>/dev/null)
  case "$APPLY_CODE" in
    update-verification-failed|post-update-inspection-failed|updated-wrong-install)
      RESULT="update-verification-failed" ;;
    *) RESULT="update-failed" ;;
  esac
  echo "devstride plugin: automatic update could not prove a tagged release was installed (this session runs $RUNNING). Run /devstride:update for the exact reason and safe retry."
  finish
fi

RESULT="behind"
echo "devstride plugin: $RUNNING running, $NEWEST available. Run /devstride:update; it will verify the exact tagged install before asking you to reload."
finish
