#!/bin/bash
# skills/release/scripts/clearance-github.sh — the built-in release clearance provider.
#
# One cleared release at a time, for every machine and account that releases this repository,
# with nothing but git and `gh`. The clearance is a custom git ref in the repository (default
# `refs/clearance/release`) pointing at an annotated tag object whose message is the clearance
# record as JSON. Every move of that ref is a compare-and-swap through `git push
# --force-with-lease=<ref>:<expected>`: a claim expects the ref to be ABSENT, a heartbeat, an
# adoption or a stale takeover expects the exact object it read, and the server rejects every
# caller whose expectation is stale — so there is no look-then-act anywhere, not even on the
# stale path. The ref is neither a branch nor a tag, so it triggers no workflow, appears in no
# branch or tag list, and no ruleset pattern matches it. The contract every command honours —
# exit codes, first lines, the local record — is skills/release/references/clearance.md, which a
# repository-supplied provider follows too.
#
#   claim     [--wait [--ignore-stuck]] [--purpose <text>]
#                                              0 CLEARED · 2 BUSY · 3 STALE (pull request open) ·
#                                              5 STUCK (--wait only) · 1 error
#   status    [--short] [--json]               0 when the ref was read (CLEAR or held) · 1 unreadable
#   heartbeat <phase> [--branch b] [--pr n]    0 · 4 NOT HOLDER
#   release   [--force] [--owed <item>]...     0 · 4 NOT HOLDER
#   adopt     --yes [--original-stopped]       0 ADOPTED · 2 not stale (or stuck and not confirmed stopped) · 4 nothing to adopt
#   owed      [--done <item>]... [--clear] [--release <name>]
#                                              0 — the close-out work still owed after a hand-back
#   keeper    (internal)                       the detached heartbeat a claim starts; see below
#
# LIVENESS. A clearance is stale when its heartbeat is older than staleMinutes (default 20). A
# release skill's phases run far longer than that with nothing to say, so `claim` and `adopt`
# start a detached KEEPER that re-stamps the heartbeat every staleMinutes/3 for as long as the
# agent process that claimed (the first non-shell ancestor of the claiming command) is alive and
# the local record still names this holder; `release` stops it. A crashed or killed agent takes
# its keeper with it, and the clearance goes stale on schedule. The skill's own `heartbeat
# <phase>` calls record progress; they are not what keeps the clearance alive.
#
# PROGRESS. Alive is not the same as moving. A heartbeat that changes the phase stamps
# phaseStartedAt; a phase with a budget (release.clearance.phaseBudgetMinutes over the defaults
# below) that runs past it is STUCK — shown by status and in every BUSY line, never taken over:
# adopting a stuck clearance that is still alive needs --original-stopped, the owner's word that
# the original session has stopped. The provider cannot prove that, so it never decides it.
#
# CLOSE-OUT OWED. A release hands clearance back before the work nothing else waits on (its
# documentation, owed messages, local clean-up). `release --owed <item>` records that work in a
# local file beside the record (<record>.owed.json), status shows it, and `owed --done <item>`
# clears it, so a session that dies after the hand-back leaves a visible trace.
#
# Configuration comes from the nearest `.claude/ds-config.json` above the working directory:
# release.clearance.{ref, staleMinutes, waitMinutes, phaseBudgetMinutes}, release.productionBranch,
# release.releaseSource, release.releaseBranchPattern and releaseTower.hotfixPattern. Environment
# overrides exist for tests and for a wrapper: CLEARANCE_REF, CLEARANCE_STALE_MINUTES,
# CLEARANCE_WAIT_MINUTES, CLEARANCE_POLL_SECONDS (default 60), CLEARANCE_RECORD (the local record
# path), CLEARANCE_REPO (owner/name), CLEARANCE_REMOTE (default origin),
# CLEARANCE_PRODUCTION_BRANCH, CLEARANCE_RELEASE_PATTERN, CLEARANCE_HOTFIX_PATTERN, CLEARANCE_NOW
# (an ISO instant, tests only), CLEARANCE_NO_KEEPER=1, CLEARANCE_OWNER_PID, CLEARANCE_KEEPER_SECONDS,
# CLEARANCE_PHASE_BUDGETS (a JSON object over the configured budgets), CLEARANCE_OWED_RECORD.
#
# Runs under macOS /bin/bash 3.2: bash only hands over to python3, the toolchain the plugin's
# hooks already assume. Needs a checkout with the remote (`origin`) that the repository's pushes
# use, and `gh` signed in (pull-request facts and the user name).
set -u
command -v python3 >/dev/null 2>&1 || { echo "clearance: python3 is required" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "clearance: gh is required (https://cli.github.com)" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "clearance: git is required" >&2; exit 1; }
CLEARANCE_SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"; export CLEARANCE_SELF
exec python3 - "$@" <<'PY'
import json, os, re, secrets, signal, socket, subprocess, sys, time
from datetime import datetime, timezone

RECORD_VERSION = 1
DEFAULT_REF = "refs/clearance/release"
DEFAULT_STALE_MINUTES = 20
DEFAULT_WAIT_MINUTES = 180
DEFAULT_HOTFIX_PATTERN = "*/hotfix/**"
# Minutes a phase may run before status calls it STUCK. Only phases that should finish in a
# bounded time have one: review and train wait on people and CI, so they have none by default.
DEFAULT_PHASE_BUDGETS = {"pre-ship": 120, "deploy": 60, "close-out": 45}
PR_LIMIT = 200  # a list this long is reported as truncated rather than trusted
SHELLS = {"sh", "bash", "zsh", "dash", "fish", "ksh", "python3", "python", "perl", "env", "timeout",
          "nohup", "script", "sandbox-exec", "caffeinate", "sudo", "su", "login", "tmux", "screen"}


def fail(message, code=1):
    print("ERROR: " + message, file=sys.stderr)
    sys.exit(code)


# ── time ──
def now():
    forced = os.environ.get("CLEARANCE_NOW")
    if forced:
        return parse_iso(forced)
    return datetime.now(timezone.utc).replace(microsecond=0)


def parse_iso(text):
    text = (text or "").strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        value = datetime.fromisoformat(text)
    except ValueError:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def age_text(since, at):
    if since is None:
        return "unknown"
    seconds = max(0, int((at - since).total_seconds()))
    if seconds < 60:
        return "%d s ago" % seconds
    if seconds < 3600:
        return "%d min ago" % (seconds // 60)
    return "%d h %d min ago" % (seconds // 3600, (seconds % 3600) // 60)


# ── the branch-patterns rule (skills/release/references/branch-patterns.md) ──
def pattern_regex(pattern):
    source, rest = "", pattern
    while rest:
        if rest.startswith("**"):
            source += ".+"; rest = rest[2:]
        elif rest.startswith("*"):
            source += "[^/]+"; rest = rest[1:]
        elif rest == "[-n]":
            source += "(-[0-9]+)?"; rest = ""
        elif re.match(r"^<[A-Z]{2}-[A-Z]{2}-[A-Z]{2}>", rest):
            source += "[0-9]{2}-[0-9]{2}-[0-9]{2}"; rest = rest[10:]
        else:
            source += re.escape(rest[0]); rest = rest[1:]
    return re.compile("^" + source + "$")


# ── configuration ──
def load_config():
    here = os.path.abspath(os.getcwd())
    while True:
        candidate = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(candidate):
            try:
                with open(candidate) as handle:
                    loaded = json.load(handle)
            except (OSError, ValueError) as error:
                fail("%s exists but cannot be read as JSON (%s) — fix it; the defaults would name a different ref" % (candidate, error))
            if not isinstance(loaded, dict):
                fail("%s is not a JSON object" % candidate)
            return loaded
        parent = os.path.dirname(here)
        if parent == here:
            return {}
        here = parent


def section(config, key):
    value = config.get(key)
    return value if isinstance(value, dict) else {}


CONFIG = load_config()
RELEASE = section(CONFIG, "release")
CLEARANCE = RELEASE.get("clearance") if isinstance(RELEASE.get("clearance"), dict) else {}
TOWER = section(CONFIG, "releaseTower")


def setting(env_name, config_value, default, kind=str):
    raw = os.environ.get(env_name)
    if raw is None or raw == "":
        raw = config_value
    if raw is None or raw == "":
        return default
    try:
        return kind(raw)
    except (TypeError, ValueError):
        return default


REF = setting("CLEARANCE_REF", CLEARANCE.get("ref"), DEFAULT_REF)
if not REF.startswith("refs/") or REF.count("/") < 2:
    fail("release.clearance.ref must be a fully qualified ref such as refs/clearance/release")
REMOTE = setting("CLEARANCE_REMOTE", None, "origin")
STALE_MINUTES = setting("CLEARANCE_STALE_MINUTES", CLEARANCE.get("staleMinutes"), DEFAULT_STALE_MINUTES, int)
WAIT_MINUTES = setting("CLEARANCE_WAIT_MINUTES", CLEARANCE.get("waitMinutes"), DEFAULT_WAIT_MINUTES, int)
POLL_SECONDS = setting("CLEARANCE_POLL_SECONDS", None, 60, int)
KEEPER_SECONDS = setting("CLEARANCE_KEEPER_SECONDS", None, max(60, STALE_MINUTES * 60 // 3), int)
PRODUCTION = setting("CLEARANCE_PRODUCTION_BRANCH", RELEASE.get("productionBranch"), "master")
RELEASE_SOURCE = RELEASE.get("releaseSource") or "develop"
RELEASE_PATTERN = setting("CLEARANCE_RELEASE_PATTERN", RELEASE.get("releaseBranchPattern"), "")
HOTFIX_PATTERN = setting("CLEARANCE_HOTFIX_PATTERN", TOWER.get("hotfixPattern"), DEFAULT_HOTFIX_PATTERN)
CACHE_DIR = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")


BUDGET_WARNINGS = []


def phase_budgets():
    """The defaults, then release.clearance.phaseBudgetMinutes, then CLEARANCE_PHASE_BUDGETS. A
    value that is not a positive number (0, null, "off") switches that phase's alarm off. A layer
    that is not an object is IGNORED with a warning, never an error: an alarm's settings must not
    stop a release from heartbeating or handing its clearance back."""
    budgets = dict(DEFAULT_PHASE_BUDGETS)
    layers = [("release.clearance.phaseBudgetMinutes", CLEARANCE.get("phaseBudgetMinutes"))]
    raw = os.environ.get("CLEARANCE_PHASE_BUDGETS")
    if raw:
        try:
            layers.append(("CLEARANCE_PHASE_BUDGETS", json.loads(raw)))
        except ValueError:
            layers.append(("CLEARANCE_PHASE_BUDGETS", raw))
    for name, layer in layers:
        if layer is None:
            continue
        if not isinstance(layer, dict):
            BUDGET_WARNINGS.append("%s ignored: it must be an object of phase → minutes" % name)
            continue
        for phase, minutes in layer.items():
            phase = str(phase)
            if minutes is None or (isinstance(minutes, (int, float)) and not isinstance(minutes, bool) and minutes <= 0):
                budgets.pop(phase, None)  # an explicit 0 or null switches the alarm off
            elif isinstance(minutes, (int, float)) and not isinstance(minutes, bool):
                budgets[phase] = int(minutes)
            else:
                BUDGET_WARNINGS.append("%s.%s ignored: %r is not a number of minutes" % (name, phase, minutes))
    return budgets


PHASE_BUDGETS = phase_budgets()


def record_path():
    """The local record, one file per repository: two repositories claimed under one account must
    not overwrite each other's (a keeper reads it to know it still serves its holder)."""
    return os.environ.get("CLEARANCE_RECORD") or os.path.join(
        CACHE_DIR, "devstride", "release-clearance", repo().replace("/", "__") + ".json")


def is_release_head(name):
    if RELEASE_PATTERN:
        return bool(pattern_regex(RELEASE_PATTERN).match(name))
    return name == RELEASE_SOURCE


def is_hotfix_head(name):
    return bool(pattern_regex(HOTFIX_PATTERN).match(name))


# ── tools ──
class ToolError(Exception):
    def __init__(self, text, rejected=False):
        super().__init__(text)
        self.text = text
        self.rejected = rejected


def run(args, body=None):
    proc = subprocess.run(args, input=body, capture_output=True, text=True)
    if proc.returncode == 0:
        return proc.stdout
    text = (proc.stderr or proc.stdout or "").strip()
    raise ToolError(text or "%s failed" % args[0])


def gh(args):
    return run(["gh", *args])


def gh_json(args):
    out = gh(args)
    try:
        return json.loads(out) if out.strip() else None
    except ValueError:
        raise ToolError("gh returned something that is not JSON: " + out[:200])


_repo = None


def repo():
    global _repo
    if _repo is None:
        _repo = os.environ.get("CLEARANCE_REPO") or gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()
        if not re.match(r"^[^/\s]+/[^/\s]+$", _repo):
            fail("could not determine the repository (gh repo view); is this a GitHub checkout?")
    return _repo


def gh_user():
    try:
        return gh(["api", "user", "--jq", ".login"]).strip() or "unknown"
    except ToolError:
        return "unknown"


# ── identity (the same rule as a pool lease: one identity means one thing everywhere) ──
def holder():
    token = os.environ.get("DEVSTRIDE_LEASE_TOKEN")
    if token:
        if re.search(r"[|\s]", token):
            fail("DEVSTRIDE_LEASE_TOKEN cannot contain | or whitespace")
        return token, False
    ids = []
    if os.environ.get("CODEX_THREAD_ID"):
        ids.append("codex:" + os.environ["CODEX_THREAD_ID"])
    if os.environ.get("CLAUDE_CODE_SESSION_ID"):
        ids.append("claude:" + os.environ["CLAUDE_CODE_SESSION_ID"])
    if ids:
        return "+".join(ids), False
    return "token:" + secrets.token_hex(12), True


# ── the ref and its record, through git ──
def remote_sha(ref):
    """The sha the remote holds for a ref, or None when the ref does not exist. Raises when the
    remote cannot be asked (not signed in, no network, no such remote): never read as clear."""
    proc = subprocess.run(["git", "ls-remote", "--exit-code", REMOTE, ref], capture_output=True, text=True)
    if proc.returncode == 2:
        return None
    if proc.returncode != 0:
        raise ToolError((proc.stderr or proc.stdout).strip() or "git ls-remote failed")
    line = proc.stdout.strip().splitlines()
    return line[0].split()[0] if line else None


def read_record():
    """The clearance record (with its object sha as `_sha`), or None when the ref is absent."""
    sha = remote_sha(REF)
    if sha is None:
        return None
    # Bring the object here (fetching the ref is always allowed; a bare sha may not be).
    have = subprocess.run(["git", "cat-file", "-e", sha], capture_output=True).returncode == 0
    if not have:
        run(["git", "fetch", "-q", REMOTE, REF])
        if subprocess.run(["git", "cat-file", "-e", sha], capture_output=True).returncode != 0:
            # The ref moved between the two calls: read what we fetched instead.
            sha = run(["git", "rev-parse", "FETCH_HEAD"]).strip()
    raw = run(["git", "cat-file", "-p", sha])
    message = raw.split("\n\n", 1)[1] if "\n\n" in raw else ""
    try:
        record = json.loads(message)
    except ValueError:
        record = None
    if not isinstance(record, dict) or not isinstance(record.get("holder"), str) or not record["holder"] \
            or parse_iso(record.get("takenAt")) is None:
        # Something that is not a clearance record holds the ref. Nobody may take it over
        # silently: it is reported, and only the owner's `release --force` clears it.
        record = {"_invalid": True}
    record["_sha"] = sha
    return record


def unreadable(record):
    return bool(record) and record.get("_invalid") is True


def write_tag(record):
    """A new tag object carrying the record, in the local object store; returns its sha. It points
    at a blob of the same text, written here too, so the push never needs a commit this checkout
    may not have fetched (the production head right after a merge on GitHub, say)."""
    clean = {k: v for k, v in record.items() if not k.startswith("_")}
    text = json.dumps(clean, sort_keys=True)
    blob = run(["git", "hash-object", "-w", "--stdin"], text + "\n").strip()
    body = "object %s\ntype blob\ntag release-clearance\ntagger release-clearance <release-clearance@devstride.plugin> %d +0000\n\n%s\n" % (
        blob, int(time.time()), text)
    return run(["git", "hash-object", "-t", "tag", "-w", "--stdin"], body).strip()


def push_ref(new_sha, expected):
    """Move the ref to new_sha (or delete it when new_sha is None) only if the remote still has
    `expected` ('' = absent). Returns True; raises ToolError(rejected=True) when the lease failed."""
    spec = ("%s:%s" % (new_sha, REF)) if new_sha else (":" + REF)
    # --no-verify: the ref carries no code, and a repository's pre-push hook (type-checks, a
    # generator that amends HEAD) is for its branches — not for every heartbeat and keeper tick.
    proc = subprocess.run(["git", "push", "-q", "--no-verify", REMOTE, spec, "--force-with-lease=%s:%s" % (REF, expected or "")],
                          capture_output=True, text=True)
    if proc.returncode == 0:
        return True
    text = (proc.stderr or proc.stdout or "").strip()
    if "rejected" in text or "stale info" in text or "declined" in text:
        raise ToolError(text, rejected=True)
    raise refusal(text)


def refusal(text):
    """The error for a push the server refused: its own words first, and the ruleset finding when
    they point at one."""
    first = text.splitlines()[0] if text else "git push failed"
    if "403" in text or "protected" in text.lower() or "rule" in text.lower():
        return ToolError("%s — pushing %s was refused; a repository ruleset that restricts ref creation blocks "
                         "the clearance ref (clearance.md)" % (first, REF))
    return ToolError(first)


def lost_race(error, expected, stuck):
    """A rejected compare-and-swap is a lost race only when the ref MOVED. The same ref after three
    rejections is the server refusing the push (a hook, a ruleset): raise it instead of retrying
    forever. Returns the new stuck count."""
    if remote_sha(REF) != expected:
        return 0
    if stuck + 1 >= 3:
        raise refusal(error.text)
    return stuck + 1


def is_stale(record, at):
    beat = parse_iso(record.get("heartbeatAt") or record.get("takenAt"))
    return beat is None or (at - beat).total_seconds() > STALE_MINUTES * 60


def phase_minutes(record, at):
    """Whole minutes the record has been in its current phase, or None when it does not say (a
    record written before phaseStartedAt existed)."""
    start = parse_iso(record.get("phaseStartedAt"))
    if start is None:
        return None
    return max(0, int((at - start).total_seconds()) // 60)


def is_stuck(record, at):
    """Alive is not moving: the current phase has a budget and has run past it."""
    if not record or unreadable(record) or is_stale(record, at):
        return False  # a stale clearance is not alive, so it cannot be stuck
    budget = PHASE_BUDGETS.get(record.get("phase") or "")
    minutes = phase_minutes(record, at)
    return bool(budget) and minutes is not None and minutes > budget


def pr_state(number):
    try:
        return gh(["pr", "view", str(number), "--repo", repo(), "--json", "state", "--jq", ".state"]).strip().upper()
    except ToolError:
        return "UNKNOWN"


# ── the local record (what a hook reads to answer "does THIS session hold clearance?") ──
def owed_path():
    """The close-out-owed file beside the local record: the record itself means "this session holds
    clearance" to a hook, so work owed after the hand-back cannot live in it."""
    forced = os.environ.get("CLEARANCE_OWED_RECORD")
    if forced:
        return forced
    base = record_path()
    return (base[:-5] if base.endswith(".json") else base) + ".owed.json"


def read_owed():
    """Entries for this repository, oldest first; never raises (status must not fail on it, and
    --short must keep working with gh down, so the repository is asked for only when some owed
    file exists at all)."""
    if not os.environ.get("CLEARANCE_OWED_RECORD") and not os.environ.get("CLEARANCE_RECORD"):
        directory = os.path.join(CACHE_DIR, "devstride", "release-clearance")
        try:
            if not any(name.endswith(".owed.json") for name in os.listdir(directory)):
                return []
        except OSError:
            return []
    try:
        path = owed_path()
    except (ToolError, SystemExit):
        return []
    try:
        with open(path) as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return []
    entries = value.get("entries") if isinstance(value, dict) else None
    if not isinstance(entries, list):
        return []
    try:
        here = repo()
    except (ToolError, SystemExit):
        here = None
    return [e for e in entries if isinstance(e, dict) and e.get("repo") in (None, here)
            and isinstance(e.get("owed"), list) and e["owed"]]


def write_owed(entries):
    directory = os.path.dirname(owed_path())
    if directory:
        os.makedirs(directory, exist_ok=True)
    if not entries:
        try:
            os.remove(owed_path())
        except OSError:
            pass
        return
    tmp = "%s.%d.tmp" % (owed_path(), os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump({"entries": entries}, handle)
    os.replace(tmp, owed_path())


def owed_line(entry, at):
    where = entry.get("release") or "release"
    if entry.get("pr"):
        where += " #%s" % entry["pr"]
    return "%s — %s (handed back %s by %s on %s, session %s)" % (
        where, ", ".join(str(i) for i in entry["owed"]), age_text(parse_iso(entry.get("releasedAt")), at),
        entry.get("user") or "?", entry.get("machine") or "?", entry.get("holder") or "?")


def read_local():
    try:
        with open(record_path()) as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def write_local(record, keeper_pid=None):
    directory = os.path.dirname(record_path())
    os.makedirs(directory, exist_ok=True)
    current = read_local() or {}
    payload = {
        "repo": repo(), "holder": record.get("holder"), "user": record.get("user"),
        "machine": record.get("machine"), "branch": record.get("branch"), "pr": record.get("pr"),
        "takenAt": record.get("takenAt"),
        "keeperPid": keeper_pid if keeper_pid is not None else (current.get("keeperPid") if current.get("repo") == repo() else None),
    }
    tmp = record_path() + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle)
    os.chmod(tmp, 0o600)
    os.replace(tmp, record_path())


def remove_local(me=None):
    """Remove this repository's record when it names `me` (None: whoever's it is — the owner's
    --force, or a record with no holder), stopping its keeper; another holder's stays."""
    current = read_local()
    if current is None or current.get("repo") not in (None, repo()):
        return
    if me is not None and current.get("holder") not in (None, me):
        return
    stop_keeper(current)
    try:
        os.remove(record_path())
    except OSError:
        pass


def lost_holding(me):
    """This session no longer holds the clearance: a local record naming it is now wrong."""
    remove_local(me)


# ── the keeper ──
def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def owner_pid():
    """The agent process that is running this command: the first ancestor that is not a shell
    or a wrapper. Its death is what makes a clearance go stale."""
    forced = os.environ.get("CLEARANCE_OWNER_PID")
    if forced:
        return int(forced) if forced.isdigit() else None
    pid = os.getppid()
    for _ in range(12):
        if pid <= 1:
            return None
        try:
            out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
        except OSError:
            return None
        if len(out) < 2:
            return None
        parent, comm = out[0], os.path.basename(out[1])
        if comm not in SHELLS:
            return pid
        pid = int(parent) if parent.isdigit() else 0
    return None


def start_keeper(me):
    """Detach a keeper for this holder. Returns its pid, or None (and says why) when none runs."""
    if os.environ.get("CLEARANCE_NO_KEEPER"):
        return None
    owner = owner_pid()
    if owner is None:
        progress("no keeper: the owning process could not be found — run heartbeat yourself at least every %d minutes" % STALE_MINUTES)
        return None
    # The repository is handed over resolved: a keeper that asked gh at its first tick would die
    # for good on one transient failure, and the clearance would go stale during a long phase.
    env = dict(os.environ, CLEARANCE_KEEPER_HOLDER=me, CLEARANCE_KEEPER_OWNER=str(owner), CLEARANCE_REPO=repo())
    env.pop("CLEARANCE_NOW", None)
    proc = subprocess.Popen(["bash", os.environ["CLEARANCE_SELF"], "keeper"], env=env, cwd=os.getcwd(),
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    return proc.pid


def stop_keeper(local):
    pid = (local or {}).get("keeperPid")
    if isinstance(pid, int) and pid > 1 and alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass


def cmd_keeper(_args):
    me = os.environ.get("CLEARANCE_KEEPER_HOLDER")
    owner = int(os.environ.get("CLEARANCE_KEEPER_OWNER") or "0")
    if not me or owner <= 1:
        return 1
    while True:
        time.sleep(KEEPER_SECONDS)
        if not alive(owner):
            return 0
        local = read_local()
        if not local or local.get("repo") != repo() or local.get("holder") != me:
            return 0
        try:
            record = read_record()
            if record is None or unreadable(record) or record.get("holder") != me:
                return 0
            record["heartbeatAt"] = iso(now())
            push_ref(write_tag(record), record["_sha"])
        except ToolError:
            continue  # a failed stamp is retried next tick; the owner's death still ends it


# ── output lines ──
def describe(record, at):
    if unreadable(record):
        return "UNREADABLE record at %s (not a clearance record) — the owner clears it with release --force" % record["_sha"][:12]
    beat = parse_iso(record.get("heartbeatAt") or record.get("takenAt"))
    line = "held by %s on %s since %s, phase %s, heartbeat %s" % (
        record.get("user") or "?", record.get("machine") or "?", record.get("takenAt") or "?",
        record.get("phase") or "?", age_text(beat, at))
    where = []
    if record.get("branch"):
        where.append(record["branch"])
    if record.get("pr"):
        where.append("#%s" % record["pr"])
    if where:
        line += " — " + " ".join(where)
    if is_stale(record, at):
        line += " — STALE"
    if is_stuck(record, at):
        line += " — STUCK in %s for %d min (budget %d min), session %s on %s" % (
            record.get("phase"), phase_minutes(record, at), PHASE_BUDGETS[record.get("phase")],
            record.get("holder") or "?", record.get("machine") or "?")
    return line


def option(args, name):
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            fail("%s needs a value" % name, 1)
        return args[i + 1]
    return None


def pr_number(value):
    text = str(value).lstrip("#").strip()
    return int(text) if text.isdigit() else text


# ── commands ──
def progress(line):
    print(line, file=sys.stderr, flush=True)


def renew(record, me, at):
    """Re-stamp a record this session holds (a claim or adoption by the holder itself). Returns the
    rejecting error when the lease failed, None when the stamp landed."""
    record["heartbeatAt"] = iso(at)
    try:
        push_ref(write_tag(record), record["_sha"])
    except ToolError as error:
        if not error.rejected:
            raise
        return error
    return None


def keeper_for(me):
    local = read_local() or {}
    keeper = local.get("keeperPid") if local.get("repo") == repo() else None
    return keeper if isinstance(keeper, int) and alive(keeper) else start_keeper(me)


def cmd_claim(args):
    wait = "--wait" in args
    stop_on_stuck = wait and "--ignore-stuck" not in args
    purpose = option(args, "--purpose") or "release"
    me, print_token = holder()
    if print_token:
        progress("holder token %s — export it as DEVSTRIDE_LEASE_TOKEN for heartbeat and release" % me)
    user = None
    deadline = time.monotonic() + WAIT_MINUTES * 60
    stuck = 0
    while True:
        at = now()
        try:
            current = read_record()
        except ToolError as error:
            # A wait of hours must not end on one failed read; outside a wait it is the error.
            if not wait or time.monotonic() >= deadline:
                raise
            progress("UNKNOWN (%s) — polling again" % (error.text.splitlines()[0] if error.text else "the ref could not be read"))
            time.sleep(POLL_SECONDS)
            continue
        if unreadable(current):
            print("ERROR: " + describe(current, at))
            return 1
        if user is None:
            user = gh_user()
        if current is None or (is_stale(current, at) and current.get("holder") != me):
            if current is not None:
                number = current.get("pr")
                state = pr_state(number) if number else "NONE"
                if state == "UNKNOWN":
                    print("ERROR: the state of pull request #%s could not be read, so the stale clearance (%s) "
                          "cannot be judged" % (number, describe(current, at)))
                    return 1
                if state in ("OPEN", "MERGED"):
                    why = "still open" if state == "OPEN" else "merged but the release was never closed out"
                    print("STALE %s — pull request #%s %s — adopt or wait" % (describe(current, at), number, why))
                    return 3
            record = {
                "v": RECORD_VERSION, "repo": repo(), "holder": me, "user": user, "machine": socket.gethostname(),
                "purpose": purpose, "phase": "claimed", "branch": None, "pr": None,
                "takenAt": iso(at), "heartbeatAt": iso(at), "phaseStartedAt": iso(at),
            }
            try:
                # Absent → the lease expects no ref; stale → the lease expects exactly the stale
                # object. Either way the server decides, and a loser reads who won.
                push_ref(write_tag(record), None if current is None else current["_sha"])
            except ToolError as error:
                if not error.rejected:
                    raise
                stuck = lost_race(error, None if current is None else current["_sha"], stuck)
                continue
            if current is not None:
                progress("stale clearance taken over (%s; pull request %s)" % (
                    describe(current, at), ("#%s %s" % (number, state.lower())) if number else "never opened"))
            write_local(record, start_keeper(me))
            print("CLEARED %s %s" % (me, record["takenAt"]))
            return 0
        if current.get("holder") == me:
            rejected = renew(current, me, at)
            if rejected is not None:
                stuck = lost_race(rejected, current["_sha"], stuck)
                continue  # moved under us: read again
            write_local(current, keeper_for(me))
            print("CLEARED %s %s (already held by this session; heartbeat renewed)" % (me, current.get("takenAt")))
            return 0
        line = "BUSY " + describe(current, at)
        if stop_on_stuck and is_stuck(current, at):
            # Alive but not moving: end the wait once so the waiting session can tell the owner;
            # it waits again with --ignore-stuck. Nothing is taken over.
            print("STUCK " + describe(current, at))
            return 5
        if not wait or time.monotonic() >= deadline:
            print(line)
            return 2
        progress(line)
        time.sleep(POLL_SECONDS)


def list_prs(state, since=None):
    """Pull requests into production in `state`; with `since` (an ISO time), only those merged on
    or after its date, so a production branch with years of merges never fills the page."""
    fields = "number,headRefName,isDraft,createdAt,mergedAt"
    args = ["pr", "list", "--repo", repo(), "--base", PRODUCTION, "--state", state, "--limit", str(PR_LIMIT), "--json", fields]
    if since:
        args += ["--search", "merged:>=" + since[:10]]
    try:
        rows = gh_json(args) or []
    except ToolError:
        return None
    return [row for row in rows if isinstance(row, dict)]


def derive(record, at):
    """What GitHub says about release pull requests and hotfix landings — never recorded."""
    out = {"onFinal": None, "waiting": [], "hotfixesLanded": [], "derived": True}
    open_prs = list_prs("open")
    if open_prs is None or len(open_prs) >= PR_LIMIT:
        out["derived"] = False
        return out
    releases = sorted((p for p in open_prs if is_release_head(p.get("headRefName", ""))), key=lambda p: p["number"])
    if releases:
        first = releases[0]
        out["onFinal"] = {"number": first["number"], "head": first["headRefName"], "draft": bool(first.get("isDraft"))}
        out["waiting"] = [{"number": p["number"], "head": p["headRefName"], "draft": bool(p.get("isDraft"))} for p in releases[1:]]
    if record:
        since = parse_iso(record.get("takenAt"))
        merged = list_prs("merged", since=record.get("takenAt"))
        if merged is None or len(merged) >= PR_LIMIT:
            out["derived"] = False
        else:
            for p in merged:
                when = parse_iso(p.get("mergedAt"))
                if is_hotfix_head(p.get("headRefName", "")) and when and since and when >= since:
                    out["hotfixesLanded"].append({"number": p["number"], "head": p["headRefName"], "mergedAt": p.get("mergedAt")})
    return out


def cmd_status(args):
    at = now()
    try:
        record = read_record()
    except ToolError as error:
        first = error.text.splitlines()[0] if error.text else "unreadable"
        if "--json" in args:
            print(json.dumps({"state": "unknown", "error": first}))
        elif "--short" not in args:
            print("UNKNOWN (%s)" % first)
        return 1
    if unreadable(record):
        if "--json" in args:
            print(json.dumps({"state": "unknown", "error": describe(record, at), "ref": REF, "sha": record["_sha"]}))
        elif "--short" not in args:
            print("UNKNOWN (%s)" % describe(record, at))
        return 1
    stale = bool(record) and is_stale(record, at)
    stuck = is_stuck(record, at)
    owed = read_owed()
    if "--short" in args:
        if record:
            what = record.get("branch") or record.get("purpose") or "release"
            print("%s · %s · %s%s%s" % (what, record.get("user") or "?", record.get("phase") or "?",
                                        " · STALE" if stale else "", " · STUCK" if stuck else ""))
        elif owed:
            latest = owed[-1]
            print("close-out owed · %s · %s" % (latest.get("release") or "release", ", ".join(str(i) for i in latest["owed"])))
        return 0
    facts = derive(record, at)
    if "--json" in args:
        clean = {k: v for k, v in (record or {}).items() if not k.startswith("_")} if record else None
        print(json.dumps({
            "state": "held" if record else "clear", "stale": stale, "staleMinutes": STALE_MINUTES,
            "stuck": stuck, "phaseMinutes": phase_minutes(record, at) if record else None,
            "phaseBudgetMinutes": PHASE_BUDGETS, "closeOutOwed": owed, "warnings": BUDGET_WARNINGS,
            "now": iso(at), "ref": REF, "repo": repo(), "productionBranch": PRODUCTION, "record": clean, **facts,
        }, sort_keys=True))
        return 0
    print("Clearance: " + describe(record, at) if record else "CLEAR")
    if facts["onFinal"]:
        f = facts["onFinal"]
        print("On final: #%s %s%s" % (f["number"], f["head"], " (draft)" if f["draft"] else ""))
    for w in facts["waiting"]:
        print("Waiting: #%s %s%s" % (w["number"], w["head"], " (draft)" if w["draft"] else ""))
    for h in facts["hotfixesLanded"]:
        print("Hotfix landed: #%s %s %s" % (h["number"], h["head"], h["mergedAt"]))
    if not facts["derived"]:
        print("(pull requests into %s could not be listed)" % PRODUCTION)
    for entry in owed:
        print("Close-out owed: " + owed_line(entry, at))
    for warning in BUDGET_WARNINGS:
        print("(%s)" % warning)
    return 0


def cmd_heartbeat(args):
    if not args or args[0].startswith("--"):
        fail("heartbeat needs a phase as its first argument", 1)
    phase = args[0]
    me, _ = holder()
    at = now()
    record = read_record()
    if record is None:
        print("NOT HOLDER: no clearance is held (claim first)")
        lost_holding(me)
        return 4
    if unreadable(record) or record.get("holder") != me:
        print("NOT HOLDER: " + describe(record, at))
        lost_holding(me)
        return 4
    if record.get("phase") != phase or not record.get("phaseStartedAt"):
        record["phaseStartedAt"] = iso(at)
    record["phase"] = phase
    branch = option(args, "--branch")
    number = option(args, "--pr")
    if branch:
        record["branch"] = branch
    if number:
        record["pr"] = pr_number(number)
    record["heartbeatAt"] = iso(at)
    stuck = 0
    while True:
        try:
            push_ref(write_tag(record), record["_sha"])
            break
        except ToolError as error:
            if not error.rejected:
                raise
            current = read_record()
            if current is None or unreadable(current) or current.get("holder") != me:
                print("NOT HOLDER: " + (describe(current, at) if current else "the clearance was released under this session"))
                lost_holding(me)
                return 4
            # This session's own keeper stamped the ref between the read and the push: carry on
            # from the object it wrote. NOT HOLDER is for a record naming someone else.
            stuck = lost_race(error, record["_sha"], stuck)
            record["_sha"] = current["_sha"]
    write_local(record)
    print("HEARTBEAT %s %s" % (phase, record["heartbeatAt"]))
    return 0


def options(args, name):
    values = []
    for i, arg in enumerate(args):
        if arg == name:
            if i + 1 >= len(args) or args[i + 1].startswith("--"):
                fail("%s needs a value" % name, 1)
            values.append(args[i + 1])
    return values


def record_owed(items, record, me, at):
    """Append (or replace) this release's close-out-owed entry. Prints the second line."""
    if not items:
        return
    local = read_local() or {}
    source = record if record and not unreadable(record) else local
    name = source.get("branch") or source.get("purpose") or "release"
    entry = {"repo": repo(), "release": name, "pr": source.get("pr"), "holder": me,
             "user": source.get("user") if source.get("holder") == me else gh_user(),
             "machine": socket.gethostname(), "releasedAt": iso(at), "owed": list(dict.fromkeys(items))}
    # One entry per release: the name repeats when no release branch is cut ("release"), so the
    # pull request tells two releases apart.
    entries = [e for e in read_owed() if (e.get("release"), e.get("pr")) != (name, entry["pr"])]
    entries.append(entry)
    write_owed(entries)
    print("Close-out owed: " + ", ".join(entry["owed"]))


def cmd_release(args):
    force = "--force" in args
    owed_items = options(args, "--owed")
    me, _ = holder()
    at = now()
    record = read_record()
    if record is None:
        print("CLEAR (nothing to release)")
        record_owed(owed_items, None, me, at)
        remove_local(None if force else me)
        return 0
    if (unreadable(record) or record.get("holder") != me) and not force:
        print("NOT HOLDER: " + describe(record, at) + " — the holder releases it, or the owner runs release --force")
        lost_holding(me)
        return 4
    if force:
        progress("forcing release of a clearance " + describe(record, at))
    stuck = 0
    while True:
        try:
            push_ref(None, record["_sha"])
            break
        except ToolError as error:
            if not error.rejected:
                raise
            current = read_record()
            if current is None:
                break  # released meanwhile: nothing left to delete
            if not force and (unreadable(current) or current.get("holder") != me):
                print("NOT HOLDER: " + describe(current, at))
                lost_holding(me)
                return 4
            # The keeper's own stamp moved it (or, forcing, anyone's): delete the object now there.
            stuck = lost_race(error, record["_sha"], stuck)
            record["_sha"] = current["_sha"]
    remove_local(None if force else me)
    print("RELEASED %s" % (record.get("branch") or record.get("purpose") or "release"))
    record_owed(owed_items, record, me, at)
    return 0


def cmd_owed(args):
    """List, settle or clear the close-out work owed after a hand-back. Local, advisory, never
    fails: any session on this machine may settle it (the one that owed it may be gone)."""
    at = now()
    entries = read_owed()
    done = options(args, "--done")
    name = option(args, "--release")
    if done or "--clear" in args:
        target = [e for e in entries if e.get("release") == name] if name else entries[-1:]
        if not target:
            print("NONE (nothing owed%s)" % (" for " + name if name else ""))
            return 0
        entry = target[-1]
        if "--clear" in args:
            entry["owed"] = []
        else:
            missing = [i for i in done if i not in entry["owed"]]
            if missing:
                progress("not owed: " + ", ".join(missing))
            entry["owed"] = [i for i in entry["owed"] if i not in done]
        entries = [e for e in entries if e["owed"]]
        write_owed(entries)
    if not entries:
        print("NONE")
        return 0
    for entry in entries:
        print("OWED " + owed_line(entry, at))
    return 0


def cmd_adopt(args):
    if "--yes" not in args:
        fail("adopt takes --yes: it rewrites the holder of a stale clearance", 1)
    me, print_token = holder()
    at = now()
    record = read_record()
    if record is None:
        print("NOT HOLDER: no clearance to adopt (claim instead)")
        return 4
    if unreadable(record):
        print("ERROR: " + describe(record, at))
        return 1
    if record.get("holder") == me:
        if renew(record, me, at) is None:
            write_local(record, keeper_for(me))
            print("ADOPTED (already held by this session; heartbeat renewed) %s %s" % (record.get("branch") or "-", ("#%s" % record["pr"]) if record.get("pr") else "-"))
            return 0
        record = read_record()
        if record is None:
            print("NOT HOLDER: no clearance to adopt (claim instead)")
            return 4
    if not is_stale(record, at):
        if not is_stuck(record, at):
            print("BUSY " + describe(record, at) + " — not stale, nothing to adopt")
            return 2
        if "--original-stopped" not in args:
            # Alive but not moving. The provider cannot prove the original session has stopped,
            # and two live sessions closing out one release send everything twice.
            print("BUSY " + describe(record, at) + " — stuck but alive: adopt only on the owner's yes, once the "
                  "original session has stopped (adopt --yes --original-stopped)")
            return 2
        progress("adopting a stuck clearance whose session was confirmed stopped: " + describe(record, at))
    if print_token:
        progress("holder token %s — export it as DEVSTRIDE_LEASE_TOKEN for heartbeat and release" % me)
    record.update({"holder": me, "user": gh_user(), "machine": socket.gethostname(), "heartbeatAt": iso(at),
                   "phaseStartedAt": iso(at)})
    try:
        push_ref(write_tag(record), record["_sha"])
    except ToolError as error:
        if not error.rejected:
            raise
        current = read_record()
        print("BUSY " + (describe(current, at) if current else "the clearance was released meanwhile — claim instead"))
        return 2
    write_local(record, start_keeper(me))
    print("ADOPTED %s %s" % (record.get("branch") or "-", ("#%s" % record["pr"]) if record.get("pr") else "-"))
    print("Resume: branch %s, pull request %s, phase %s" % (
        record.get("branch") or "none cut yet", ("#%s" % record["pr"]) if record.get("pr") else "none opened yet", record.get("phase")))
    return 0


COMMANDS = {"claim": cmd_claim, "status": cmd_status, "heartbeat": cmd_heartbeat, "release": cmd_release,
            "adopt": cmd_adopt, "owed": cmd_owed, "keeper": cmd_keeper}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: clearance-github.sh <claim [--wait [--ignore-stuck]] [--purpose t] | status [--short] [--json] | "
              "heartbeat <phase> [--branch b] [--pr n] | release [--force] [--owed item]... | "
              "adopt --yes [--original-stopped] | owed [--done item]... [--clear] [--release name]>")
        return 0 if argv else 1
    command = COMMANDS.get(argv[0])
    if command is None:
        fail("unknown command %s" % argv[0], 1)
    try:
        return command(argv[1:])
    except ToolError as error:
        print("ERROR: %s" % (error.text.splitlines()[0] if error.text else "a git or gh call failed"), file=sys.stderr)
        return 1


sys.exit(main(sys.argv[1:]))
PY
