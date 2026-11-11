#!/usr/bin/env python3
"""hooks/session-runtime.py — which devstride plugin a Claude Code session is RUNNING.

`claude plugin list` reads disk, and a session serves the copy it loaded until `/reload-plugins` or a
restart, so after an update the two disagree and nothing in the session says so. Only the plugin's
own hooks receive `CLAUDE_PLUGIN_ROOT` (the loaded copy), and the status-line payload carries no
plugin data, so the loaded copy writes down what it is:

  record   (SessionStart, every source) reads the hook payload on stdin and writes
           ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/sessions/<session_id>.json =
           {schema: 1, running, root, transcript, at[, nudged][, model][, effort]}. Records older
           than 7 days are pruned at session start. `model` = {id[, name], at} and `effort` =
           {level, at} are the session's live model and effort as last seen, `at` being when that
           value was first seen: taken from this payload when it carries them, else carried over.
  seen     (every PreToolUse of the main conversation, and every PostModelSwitch, whose payload
           names the new model as `to_model`; a helper agent's call is ignored, since it carries
           the helper's effort) reads the hook payload and, only when its effort (or model) differs
           from the record's, rewrites the record: one small read, no network, no subprocess, and
           no write at all when nothing changed or the session has no record yet.
  prompt   (every UserPromptSubmit) rewrites the same record, so the first prompt after a reload
           records what was actually loaded; refreshes the newest-release cache IN THE BACKGROUND
           when it is older than 30 minutes (so a release published mid-session reaches the status
           line and this prompt check without a restart); then, when this session runs an older
           plugin than it could, prints ONE context line asking Claude to tell or ask the person:
           once per session per target version (`nudged`), never on a loop or scheduled prompt,
           never with the check switched off, and in a pinning repository only a reload onto
           the pinned version. It changes nothing itself:
           an update stays the person's own `/devstride:update`, a reload their `/reload-plugins`.
  refresh-newest  the background half of `prompt`: one bounded `update-plugin.py latest` and an
           atomic write of newest.json in the session-start check's own format.
  check --session <id> [--repo <dir>]
           prints one JSON line {running, installed, newest, verdict}: `reload` when the session
           runs an older version than the install that applies to this repository, `update` when it
           runs that install and a newer release is published (and the repository does not pin or
           switch off the check), `current` otherwise, `unknown` when there is no record, a
           malformed one, or no single applicable install. A `/reload-plugins` in the transcript
           after the record was written reads as `current` until the next prompt rewrites it, so a
           successful reload never shows a false warning and a failed one shows again.
  models --role planning|runner [--session <id>] [--repo <dir>]
           prints one JSON line {role, expected: {model, effort}, running: {model, effort},
           verdict}: the model and effort the repository expects a session in that role to run
           (`sessionModels` in .claude/ds-config.json; planning fable/high, runner opus/high when
           absent) against what this session was last seen running. `off` when the repository
           switches the check off, `mismatch` when a value that can be compared differs, `match`
           when both agree, `unknown` otherwise (no record, a value not seen yet, or a model name
           that cannot be compared) and on any error. The session defaults to
           CLAUDE_CODE_SESSION_ID. It reports only: nothing but the person changes a session's
           model or effort. Contract: skills/plan/references/session-models.md.
  models-report [--repo <dir>]
           prints the lines doctor reports: each role's effective model and effort with its source
           (configured or shipped default), then one `WARN` line per model name that is neither a
           documented alias nor a full claude-… id and per effort outside the five levels.

The status line imports `check` and `observe` in-process (the status-line payload carries the live
model and effort); a repository's tooling runs `check`. The launcher a repository commits as its
status line (skills/setup/references/statusline-launcher.sh) reads `root` from the record's one
line, without a JSON parser, to run the loaded copy's status line. Fails open: every
error exits 0 silently (record) or reads as `unknown` (check). python3 and the standard library only.
"""
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
from datetime import datetime

SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
PLUGIN_IDS = ("devstride@devstride", "ds@devstride")
SOURCE = "https://github.com/devstride/claude-plugin"
NEWEST_TTL = 21600            # the session-start check's six hours
KEEP = 7 * 24 * 3600          # session records older than this are pruned
TAIL = 131072                 # the transcript tail read for a reload
REFRESH_AFTER = 1800          # a prompt refreshes a newest-release cache older than this
REFRESH_LOCK = 300            # one background refresh at a time; a dead one's lock lapses
FETCH_TIMEOUT = 30            # the background fetch's own bound
NUDGED = re.compile(r"^(reload|update):[0-9]+\.[0-9]+\.[0-9]+$")
MODEL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@\[\]-]{0,127}$")
MODEL_NAME = re.compile(r"^[^\x00-\x1f\x7f]{1,64}$")
EFFORT = re.compile(r"^[a-z]{1,16}$")
MODEL_ALIASES = ("default", "best", "fable", "opus", "sonnet", "haiku", "opusplan")
UNCOMPARABLE = ("default", "best", "opusplan")   # names that do not say which model runs
EFFORTS = ("low", "medium", "high", "xhigh", "max")
ROLES = {"planning": ("fable", "high"), "runner": ("opus", "high")}
LOOP_PROMPT = re.compile(r"^\s*(/loop\b|/devstride:update\b|/reload-plugins\b|<<autonomous-loop|<task-notification>)")


def cache_dir():
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "devstride-plugin")


def version_tuple(value):
    return tuple(int(part) for part in value.split("."))


def read_json(path, limit=1048576):
    """A regular file we (or root) own, opened without following a symlink; None on any doubt."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid not in (os.getuid(), 0) or info.st_size > limit:
            return None
        return json.loads(os.read(fd, limit + 1))
    except Exception:
        return None
    finally:
        os.close(fd)


def running_version(root):
    manifest = read_json(os.path.join(os.path.realpath(root), ".claude-plugin", "plugin.json"))
    if not isinstance(manifest, dict) or manifest.get("name") != "devstride":
        return None
    version = manifest.get("version")
    return version if isinstance(version, str) and SEMVER.match(version) else None


def private_dir(path):
    """Create (0700) and vouch for a directory: ours, a real directory, not a symlink."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OSError("untrusted directory")
    return path


def write_atomic(directory, name, payload):
    data = (json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n").encode()
    temporary = os.path.join(directory, ".%s.%s.tmp" % (name, secrets.token_hex(8)))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.replace(temporary, os.path.join(directory, name))  # replaces a symlink itself, never its target


def prune(directory, now):
    for name in os.listdir(directory):
        path = os.path.join(directory, name)
        try:
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and now - info.st_mtime > KEEP:
                os.unlink(path)
        except OSError:
            pass


def read_payload():
    try:
        payload = json.loads(sys.stdin.read(65536) or "{}")
        return payload if isinstance(payload, dict) else {}
    except Exception:
        return {}


def seen_values(payload):
    """(model id, model display name, effort level) as a hook or status-line payload carries them;
    None for each one that is absent or not in a shape worth recording. `model` is an object
    ({id, display_name}) in the status-line payload and may be a bare id in a hook payload."""
    # A model-switch payload names the model the session moved to as `to_model`.
    model, effort = payload.get("to_model") or payload.get("model"), payload.get("effort")
    name = None
    if isinstance(model, dict):
        model, name = model.get("id"), model.get("display_name")
    level = effort.get("level") if isinstance(effort, dict) else effort
    return (model if isinstance(model, str) and MODEL_ID.match(model) else None,
            name if isinstance(name, str) and MODEL_NAME.match(name) else None,
            level if isinstance(level, str) and EFFORT.match(level) else None)


def merge_seen(entry, previous, model, name, effort, now):
    """Put the live model and effort into `entry`: the value just seen, else the one `previous`
    held. A value keeps its `at` while it stays the same. True when `entry` now differs from
    `previous` in either."""
    previous = previous if isinstance(previous, dict) else {}
    old_model = previous.get("model") if isinstance(previous.get("model"), dict) else None
    old_effort = previous.get("effort") if isinstance(previous.get("effort"), dict) else None
    new_model, new_effort = old_model, old_effort
    if model:
        same = bool(old_model) and old_model.get("id") == model
        new_model = {"id": model, "at": old_model.get("at", now) if same else now}
        name = name or (old_model.get("name") if same else None)
        if name:
            new_model["name"] = name
    if effort and not (old_effort and old_effort.get("level") == effort):
        new_effort = {"level": effort, "at": now}
    if new_model:
        entry["model"] = new_model
    if new_effort:
        entry["effort"] = new_effort
    return new_model != old_model or new_effort != old_effort


def write_record(payload):
    """Write this session's record from the loaded copy; (directory, session id, entry) or None.
    A `nudged` marker already in the record is carried over, so a prompt never asks twice, and so
    are the live model and effort unless this payload carries newer ones."""
    sid = payload.get("session_id") or ""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or ""
    if not isinstance(sid, str) or not SESSION_ID.match(sid) or not root:
        return None
    running = running_version(root)
    if not running:
        return None
    transcript = payload.get("transcript_path")
    directory = private_dir(os.path.join(private_dir(cache_dir()), "sessions"))
    entry = {
        "schema": 1, "running": running, "root": os.path.realpath(root),
        "transcript": transcript if isinstance(transcript, str) else None, "at": round(time.time(), 3),
    }
    previous = read_json(os.path.join(directory, sid + ".json"), limit=16384)
    nudged = previous.get("nudged") if isinstance(previous, dict) else None
    if isinstance(nudged, str) and NUDGED.match(nudged):
        entry["nudged"] = nudged
    merge_seen(entry, previous, *seen_values(payload), now=entry["at"])
    write_atomic(directory, sid + ".json", entry)
    return directory, sid, entry


def observe(session, model=None, name=None, effort=None):
    """Note the live model and effort in a session's EXISTING record, writing only when one of them
    changed. True when it wrote. Never creates a record (only the loaded copy knows what it is)
    and never moves `at`, which `check` compares with the transcript. Never raises."""
    try:
        if not isinstance(session, str) or not SESSION_ID.match(session):
            return False
        model, name, effort = seen_values({"model": {"id": model, "display_name": name}, "effort": effort})
        if not model and not effort:
            return False
        directory = os.path.join(cache_dir(), "sessions")
        entry = read_json(os.path.join(directory, session + ".json"), limit=16384)
        if not isinstance(entry, dict) or entry.get("schema") != 1:
            return False
        if not merge_seen(entry, dict(entry), model, name, effort, round(time.time(), 3)):
            return False
        write_atomic(private_dir(directory), session + ".json", entry)
        return True
    except Exception:
        return False


def seen():
    payload = read_payload()
    # A helper agent's tool call carries the helper's own effort (and shares the session id): only
    # the main conversation's calls say what the session runs.
    if payload.get("agent_id"):
        return
    model, name, effort = seen_values(payload)
    observe(payload.get("session_id"), model, name, effort)


def record():
    try:
        payload = read_payload()
        written = write_record(payload)
        if written and payload.get("hook_event_name") == "SessionStart":
            prune(written[0], time.time())
    except Exception:
        pass


def git_common_dir(start):
    """The repository's shared git directory (the main checkout's .git for every linked worktree),
    found by walking up from `start` and reading `.git` files — no git process."""
    here = os.path.realpath(start)
    while True:
        dot = os.path.join(here, ".git")
        if os.path.isdir(dot):
            return here, os.path.realpath(dot)
        if os.path.isfile(dot):
            with open(dot) as fh:
                line = fh.readline().strip()
            if not line.startswith("gitdir:"):
                return here, None
            gitdir = os.path.normpath(os.path.join(here, line[len("gitdir:"):].strip()))
            common = gitdir
            commondir = os.path.join(gitdir, "commondir")
            if os.path.isfile(commondir):
                with open(commondir) as fh:
                    common = os.path.normpath(os.path.join(gitdir, fh.readline().strip()))
            return here, os.path.realpath(common)
        parent = os.path.dirname(here)
        if parent == here:
            return None, None
        here = parent


def installed_version(repo_common):
    """The one install that applies here: every user/managed row plus every project/local row
    recorded in a checkout of this repository. None when there is not exactly one."""
    registry = read_json(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                                      "plugins", "installed_plugins.json"), limit=16777216)
    plugins = (registry or {}).get("plugins") if isinstance(registry, dict) else None
    if not isinstance(plugins, dict):
        return None
    applicable = []
    for key in PLUGIN_IDS:
        for row in plugins.get(key) or []:
            if not isinstance(row, dict):
                continue
            scope, project = row.get("scope"), row.get("projectPath")
            if scope in ("user", "managed"):
                applicable.append(row)
            elif scope in ("project", "local") and isinstance(project, str) and repo_common:
                try:
                    if git_common_dir(project)[1] == repo_common:
                        applicable.append(row)
                except OSError:
                    pass
    if len(applicable) != 1:
        return None
    version = applicable[0].get("version")
    return version if isinstance(version, str) and SEMVER.match(version) else None


def newest_version(now):
    value = read_json(os.path.join(cache_dir(), "newest.json"))
    if not isinstance(value, dict) or value.get("schema") != 2 or value.get("source") != SOURCE:
        return None
    newest, fetched = value.get("newest"), value.get("fetchedAt")
    if isinstance(newest, str) and SEMVER.match(newest) and type(fetched) is int and 0 <= now - fetched < NEWEST_TTL:
        return newest
    return None


def plugin_block(top):
    config = read_json(os.path.join(top, ".claude", "ds-config.json")) if top else None
    plugin = config.get("plugin") if isinstance(config, dict) else None
    return plugin if isinstance(plugin, dict) else {}


def updates_wanted(top):
    """False when the repository pins the plugin or switches the update check off."""
    plugin = plugin_block(top)
    return plugin.get("pin") is None and plugin.get("updateCheck", True) is not False


def reloaded_since(transcript, at):
    """True when the transcript tail holds a `/reload-plugins` run after `at`."""
    if not isinstance(transcript, str) or not transcript:
        return False
    try:
        with open(transcript, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - TAIL))
            lines = fh.read().split(b"\n")
    except OSError:
        return False
    for line in lines:
        if b'"reload-plugins"' not in line:
            continue
        try:
            entry = json.loads(line)
            if entry.get("type") != "system" or (entry.get("commandRun") or {}).get("command") != "reload-plugins":
                continue
            when = datetime.fromisoformat(str(entry.get("timestamp")).replace("Z", "+00:00")).timestamp()
        except Exception:
            continue
        if when > at:
            return True
    return False


def check(session, repo=None):
    result = {"running": None, "installed": None, "newest": None, "verdict": "unknown"}
    try:
        if not isinstance(session, str) or not SESSION_ID.match(session):
            return result
        entry = read_json(os.path.join(cache_dir(), "sessions", session + ".json"))
        if not isinstance(entry, dict) or entry.get("schema") != 1:
            return result
        running, at = entry.get("running"), entry.get("at")
        if not isinstance(running, str) or not SEMVER.match(running) or not isinstance(at, (int, float)):
            return result
        result["running"] = running
        top, common = git_common_dir(repo or os.getcwd())
        installed = installed_version(common)
        now = int(time.time())
        result["installed"], result["newest"] = installed, newest_version(now)
        if not installed:
            return result
        if reloaded_since(entry.get("transcript"), at):
            result["verdict"] = "current"
        elif version_tuple(running) < version_tuple(installed):
            result["verdict"] = "reload"
        elif (running == installed and result["newest"] and updates_wanted(top)
              and version_tuple(installed) < version_tuple(result["newest"])):
            result["verdict"] = "update"
        else:
            result["verdict"] = "current"
    except Exception:
        result["verdict"] = "unknown"
    return result


def model_parts(value):
    """(base, release date or None): a model name or id, lower-cased, without what only says HOW
    the same model is reached — a context-window suffix (`[1m]`), a provider prefix before
    `claude-` (`us.anthropic.`, an ARN) and a provider version (`-v1:0`) — and its release date
    (`-20261001`, `@20261001`) apart, since two dates of one name are two models."""
    value = re.sub(r"\[[0-9a-z]+\]$", "", value.strip().lower())
    value = re.sub(r"^.*[./:](?=claude-)", "", value)
    value = re.sub(r"-v[0-9]+(:[0-9]+)?$", "", value)
    dated = re.match(r"^(.*)[-@]([0-9]{8})$", value)
    return (dated.group(1), dated.group(2)) if dated else (value, None)


def model_base(value):
    return model_parts(value)[0]


def model_matches(expected, running):
    """True / False, or None when the two cannot be compared. A full id matches the same model
    however it is reached (see model_parts); a release date matters only when BOTH name one. An
    alias matches a running id by FAMILY: the alias is one whole hyphen-separated segment of the id
    (`opus` matches claude-opus-5, never claude-opusplan-x), not a substring of it."""
    if not isinstance(expected, str) or not isinstance(running, str) or not running:
        return None
    (expected, wanted), (running, dated) = model_parts(expected), model_parts(running)
    if expected.startswith("claude-"):
        return expected == running and (wanted is None or dated is None or wanted == dated)
    if expected not in MODEL_ALIASES or expected in UNCOMPARABLE:
        return None
    return expected in running.split("-")


def models_block(repo=None):
    """The repository's `sessionModels` settings as written; {} when absent or not an object."""
    top = git_common_dir(repo or os.getcwd())[0]
    config = read_json(os.path.join(top, ".claude", "ds-config.json")) if top else None
    block = config.get("sessionModels") if isinstance(config, dict) else None
    return block if isinstance(block, dict) else {}


def models_report(repo=None):
    """The lines doctor reports: each role's effective model and effort and where each comes from,
    then one WARN per value the check cannot use. Whether the account offers a model is not
    something a local read can know, and the first line says so."""
    try:
        block = models_block(repo)
    except Exception:
        block = {}
    lines = ["session models: the model and effort each role expects (names are checked for shape "
             "only; which models this account offers cannot be read from here)"]
    if block.get("check", True) is False:
        lines.append("sessionModels.check: false — the check is switched off; skills say nothing")
    warnings = []
    for role in ROLES:
        wanted = block.get(role) if isinstance(block.get(role), dict) else {}
        parts = []
        for key, default in zip(("model", "effort"), ROLES[role]):
            value = wanted.get(key, default)
            parts.append("%s %s (%s)" % (key, json.dumps(value), "configured" if key in wanted else "shipped default"))
            if key == "model":
                base = model_base(value) if isinstance(value, str) else ""
                if base not in MODEL_ALIASES and not re.match(r"^claude-[a-z0-9][a-z0-9.-]*$", base):
                    warnings.append("WARN sessionModels.%s.model: %s is neither a documented alias (%s; [1m] may follow) "
                                    "nor a full claude-… id; the check reads it as unknown"
                                    % (role, json.dumps(value), ", ".join(MODEL_ALIASES)))
            elif value not in EFFORTS:
                warnings.append("WARN sessionModels.%s.effort: %s is not one of %s; the check reads it as unknown"
                                % (role, json.dumps(value), ", ".join(EFFORTS)))
        lines.append("sessionModels.%s: %s" % (role, ", ".join(parts)))
    return lines + warnings


def models(role, session=None, repo=None):
    result = {"role": role, "expected": {"model": None, "effort": None},
              "running": {"model": None, "effort": None}, "verdict": "unknown"}
    try:
        if role not in ROLES:
            return result
        block = models_block(repo)
        wanted = block.get(role) if isinstance(block.get(role), dict) else {}
        expected = result["expected"]
        expected["model"] = wanted.get("model", ROLES[role][0])
        expected["effort"] = wanted.get("effort", ROLES[role][1])
        if block.get("check", True) is False:
            result["verdict"] = "off"
            return result
        session = session or os.environ.get("CLAUDE_CODE_SESSION_ID")
        entry = None
        if isinstance(session, str) and SESSION_ID.match(session):
            entry = read_json(os.path.join(cache_dir(), "sessions", session + ".json"), limit=16384)
        if not isinstance(entry, dict) or entry.get("schema") != 1:
            return result
        model, _, effort = seen_values({"model": entry.get("model"), "effort": entry.get("effort")})
        result["running"] = {"model": model, "effort": effort}
        same_model = model_matches(expected["model"], model)
        same_effort = (expected["effort"] == effort) if expected["effort"] in EFFORTS and effort else None
        if same_model is False or same_effort is False:
            result["verdict"] = "mismatch"
        elif same_model and same_effort:
            result["verdict"] = "match"
    except Exception:
        result["verdict"] = "unknown"
    return result


def check_enabled():
    return os.environ.get("DEVSTRIDE_PLUGIN_UPDATE_CHECK", "1") != "0"


def refresh_due(now):
    value = read_json(os.path.join(cache_dir(), "newest.json"), limit=4096)
    fetched = value.get("fetchedAt") if isinstance(value, dict) and value.get("source") == SOURCE else None
    return not (type(fetched) is int and 0 <= now - fetched < REFRESH_AFTER)


def take_refresh_lock(now):
    """One background refresh at a time across every session on this machine; a lock older than
    REFRESH_LOCK (a refresh that died) is taken over."""
    lock = os.path.join(private_dir(cache_dir()), "newest.refresh")
    try:
        info = os.lstat(lock)
        if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and -60 < now - info.st_mtime < REFRESH_LOCK:
            return False
        os.unlink(lock)
    except FileNotFoundError:
        pass
    try:
        os.close(os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
        return True
    except OSError:
        return False


def spawn_refresh():
    """Start `refresh-newest` detached: the prompt never waits on the network."""
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    subprocess.Popen([sys.executable, os.path.realpath(__file__), "refresh-newest"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     close_fds=True, start_new_session=True, env=env)


def refresh_newest():
    """Fetch the newest published release once and store it as the session-start check does. A
    failed fetch keeps its lock, so an offline machine retries once per REFRESH_LOCK, not per prompt."""
    lock = os.path.join(cache_dir(), "newest.refresh")
    try:
        helper = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))),
                              "skills/update/scripts/update-plugin.py")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        done = subprocess.run([sys.executable, helper, "latest"], stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=FETCH_TIMEOUT, env=env)
        newest = done.stdout.strip()
        if done.returncode == 0 and SEMVER.match(newest):
            write_atomic(private_dir(cache_dir()), "newest.json",
                         {"schema": 2, "source": SOURCE, "newest": newest, "fetchedAt": int(time.time())})
            os.unlink(lock)
    except Exception:
        pass


def nudge_text(result):
    """(kind, target version, the one context line) for a session behind what it could run."""
    verdict, running = result.get("verdict"), result.get("running")
    if verdict == "reload":
        target = result.get("installed")
        return "reload", target, ("devstride plugin: this session is still running %s, and %s is installed on this machine. "
                        "Tell the user so in one short line at the start of your reply: they load it by typing "
                        "/reload-plugins themselves (you cannot run it). Then carry on with their request; if no person "
                        "is at the keyboard (a scheduled or unattended run), just mention it in your final report." % (running, target))
    if verdict == "update":
        target = result.get("newest")
        return "update", target, ("devstride plugin: this session runs %s and %s is published. Ask the user once whether to "
                        "update now: on yes, run /devstride:update and follow its handoff (they then type "
                        "/reload-plugins); on no, carry on. If you are part-way through a multi-step task, finish "
                        "the step you are on and ask before the next one. If no person is at the keyboard (a scheduled "
                        "or unattended run), do not ask: carry on and mention it in your final report." % (running, target))
    return None, None, None


def prompt():
    try:
        payload = read_payload()
        written = write_record(payload)
        if not written:
            return
        directory, sid, entry = written
        cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
        top = git_common_dir(cwd)[0]
        now = int(time.time())
        if check_enabled() and updates_wanted(top) and refresh_due(now) and take_refresh_lock(time.time()):
            spawn_refresh()
        text = payload.get("prompt")
        if isinstance(text, str) and LOOP_PROMPT.match(text):
            return
        plugin = plugin_block(top)
        if not check_enabled() or plugin.get("updateCheck", True) is False:
            return
        kind, target, line = nudge_text(check(sid, cwd))
        if not line or not isinstance(target, str) or not SEMVER.match(target):
            return
        if kind == "reload" and plugin.get("pin") is not None and plugin.get("pin") != target:
            return  # a pinned repository is told to reload only onto its pinned version
        marker = "%s:%s" % (kind, target)
        if entry.get("nudged") == marker:
            return
        entry["nudged"] = marker
        write_atomic(directory, sid + ".json", entry)
        print(line)
    except Exception:
        pass


def main(argv):
    if argv[:1] == ["record"]:
        record()
        return 0
    if argv[:1] == ["prompt"]:
        prompt()
        return 0
    if argv[:1] == ["seen"]:
        try:
            seen()
        except Exception:
            pass
        return 0
    if argv[:1] == ["models"]:
        options = dict(zip(argv[1::2], argv[2::2]))
        print(json.dumps(models(options.get("--role"), options.get("--session"), options.get("--repo")), sort_keys=True))
        return 0
    if argv[:1] == ["models-report"]:
        options = dict(zip(argv[1::2], argv[2::2]))
        print("\n".join(models_report(options.get("--repo"))))
        return 0
    if argv[:1] == ["refresh-newest"]:
        refresh_newest()
        return 0
    if argv[:1] == ["check"]:
        options = dict(zip(argv[1::2], argv[2::2]))
        print(json.dumps(check(options.get("--session"), options.get("--repo")), sort_keys=True))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
