#!/usr/bin/env python3
"""hooks/presence.py — every running session reports its live status, inside a repository or not.

A fleet view built from work claims shows only the sessions holding a claim: a session that is
reviewing, fixing, waiting on tests or waiting for its person has no row. This hook gives every
session a presence report, whatever it is doing, through one of two reporters
(skills/build-item/scripts/presence_settings.py decides, in this order):

  - off: DEVSTRIDE_PRESENCE set to 0 (false, off, no) for the machine, or `"presence": null` in the
    repository's `.claude/ds-config.json`. Nothing runs and nothing is written.
  - the repository's own command, when its block names one:

        "presence": { "command": "<the repository's own command>", "intervalMinutes": 5 }

    What a report means, where it goes and when it expires are then the repository's. A block
    whose `command` is blank runs nothing.
  - otherwise the built-in reporter, hooks/presence-report.py, every minute (or the block's
    `intervalMinutes`): it sends the report to DevStride with the API key the machine's DevStride
    connection carries, else with the machine's session reporter credential
    (skills/build-item/scripts/devstride_connection.py, reporter_credential.py). A session outside
    any repository, or in one with no block, is an ordinary session reported this way. With neither
    nothing runs and nothing is written for the session, and two things are said, both as JSON:
    every SessionStart shows the person a `systemMessage` that the session is not on the Fleet
    yet, and a prompt that runs a DevStride skill gives the model `additionalContext` asking it to
    register a session reporter credential through the signed-in connection first. Those are the
    only things this hook ever prints.

The contract: skills/setup/references/session-presence.md.

  hook     (the hook command; the event comes from the payload's hook_event_name)
           SessionStart     -> state "starting", sends `start`, starts this session's keeper when
                               none runs (as every event does; source `compact`, the session carrying on after a compaction, is
                               ignored); the session's process and its start time are always re-read,
                               and so is whether it runs with no person at it (`unattended`:
                               DEVSTRIDE_UNATTENDED=1, CLAUDE_CODE_ENTRYPOINT starting with `sdk`,
                               or `-p` / `--print` among the process's own arguments); while this
                               machine keeps a stop for the session (stopped, ended, now resumed:
                               no keeper listened while it was ended), it runs the keeper's stop
                               check once, waiting at most 3 seconds, so the session's first prompt
                               meets the server's answer, not the one kept before it ended (a slower
                               answer still lands, for the start after)
           UserPromptSubmit -> state "working"; sends `beat` on a state change, when the last send
                               is a minute old, or when the session moved to another checkout; with
                               no record yet (a session that began before the block existed or the
                               plugin was updated) or after an `end`, sends `start`
           PreToolUse       -> state "working", and the call is open (its tool_use_id and start
                               time) until it ends; the main conversation (no agent_id) calling
                               AskUserQuestion or ExitPlanMode is a question to the person: state
                               "waiting", and that call is not opened
           PostToolUse, PostToolUseFailure -> the call is closed; state "working" (a turn a
                               notification started has no prompt)
           PostToolBatch    -> every call it lists, and every open call of the same agent (the main
                               conversation, or the helper agent its agent_id names), is closed: a
                               call a deny rule, a hook or a person refused fires PreToolUse but never
                               PostToolUse; state "working"
           Notification     -> only permission_prompt, elicitation_dialog and elicitation_url_dialog
                               (state "waiting": a prompt waits on the person), elicitation_response and
                               elicitation_complete (state "working": the person answered, the call
                               goes on; not while a question is open) and idle_prompt (about
                               60 seconds after a finished turn: every open call is dropped and the
                               state is "waiting", unless the turn left background work running or
                               ended on an API error, when the state is kept and no activity is
                               stamped); any other type does nothing
           Stop             -> every open call is dropped; state "waiting", or "working" when the
                               payload's background_tasks holds one with status `running` that is not
                               a teammate (the turn left its own background work running; that moment
                               is the background mark)
           StopFailure      -> a turn ended on an API error (a usage limit, an outage): every open
                               call and the background mark are dropped, the state is kept and no
                               activity is stamped, so a session that cannot continue still reads as
                               idle while working
           SessionEnd       -> state "ended", sends `end` (PRESENCE_END_REASON = the payload's
                               reason, such as `clear` or `logout`)
           An interrupt (the person pressing Esc mid-turn, or refusing a permission prompt) fires no
           hook at all, not Stop and not the idle prompt, which follows only a finished turn or a
           local command: the keeper reads it from the session's transcript (below).
           Every event but SessionEnd, StopFailure and an ignored idle_prompt stamps the session's last
           activity (PRESENCE_ACTIVE_AT). SessionStart and UserPromptSubmit drop every open call, the
           background mark and the failed-turn flag, and keep their own time and the payload's
           transcript_path for the keeper. At most 64 calls are open (the oldest dropped).
           Every event but SessionStart and UserPromptSubmit only updates a session already reported:
           for a session with no record, or one already ended, it does nothing. Every event but those
           two and SessionEnd sends `beat` only on a state change.
           While the main conversation's question is open, no other tool call changes the state (a
           background helper's calls go on while the person decides): only that question's own
           PostToolUse or PostToolUseFailure (any main-conversation one when it carried no
           tool_use_id), a prompt, a finished turn or the idle prompt ends it.
           A state change within 30 seconds of the last send is held: the next hook or keeper send
           carries it, and the keeper sends it once those 30 seconds pass (both compare against the
           last state REPORTED, so a held change is not lost).
           The record follows the session, not the checkout: a session that moves to a place where
           reporting is off, or from a repository whose own command reports it to a place that names
           no command, keeps reporting under the one it came from, and no event is ever
           dropped for that reason for a session that has a record. The session's process
           (CLAUDE_PID, else the parent of the hook's shell) and its start time are re-read on every
           start and prompt.
           Every read-modify-write of the record holds the session's state lock (never while the
           command runs), and every queued report takes the next number in the record's sequence.
           The keeper follows the loaded plugin: every event records this file's own plugin version
           (read from the plugin it belongs to, never from CLAUDE_PLUGIN_ROOT) as the session's, and
           any event but SessionEnd, for a session with a known process, starts a keeper when none
           runs. Once per session and version, when a keeper runs that this version did not start
           (its record names no sweep by this version), the hook ends this session's keepers whose
           command line runs another copy's presence.py (`ps`, this user's processes, matched on
           `/hooks/presence.py keeper <this session>`; never another session's), waits up to half a
           second for the lock, starts its own and, when it ended one, sends `beat` at once (the ended
           keeper may have dropped a queued report): a keeper from before this check never leaves.
  keeper <session>  (detached, one per session, holding the session's keeper lock, which is how a
           hook knows one runs) wakes every 5 seconds and checks every 10: it exits once the session has ended, its
           record is gone, reporting is switched off or the connection loses its key (re-read every
           check; Claude Code's configuration file only when it changed) or the record names another plugin version than its
           own code's (an update the session has loaded), releasing its lock under the state lock so a
           resume never sees a keeper that is leaving; when the session's process is gone, or its
           process id now belongs to a process with another known start time, it sends `end`
           (reason `gone`) and exits; and it sends `beat` when the last send is `intervalMinutes`
           old or a held change is due. It covers a long turn with no prompt, and a killed session.
           While the state is "working" it also reads the end of the session's transcript (its last
           256 KB, never under the state lock): when the main conversation's last user or assistant
           entry is Claude Code's own interrupt entry (a user entry whose one text block starts
           "[Request interrupted by user"), stamped later than the session's last start or prompt
           and not already applied, the turn was interrupted and it is the person's move: every
           open call, the background mark and the failed-turn flag are dropped, the state is
           "waiting" and the interrupt's time is the last activity. The change is sent as any held
           change is. A background helper still running after the interrupt sets the state back to
           "working" at its next tool call, and the interrupt already applied does not undo that.
           Anything said after that entry, a transcript that is missing, unreadable, not the user's
           own file or cut mid-line, or an entry without a time changes nothing.
           An Esc pressed while the model is still thinking, before any reply, writes no such entry
           and fires no hook. For that one the keeper reads Claude Code's own status file for the
           session's process (${CLAUDE_CONFIG_DIR:-~/.claude}/sessions/<pid>.json): when it names
           this session and process, reads "idle", and turned idle later than the last start,
           prompt, interrupt applied and activity, while the session left no background work running
           and no turn failed, the interrupt is applied the same way at that time. A missing,
           unreadable or foreign file, or any other status, changes nothing.
           It also asks DevStride whether a person stopped the session: the built-in reporter's
           `stop-sync` (hooks/presence-report.py), every 15 seconds while the state is "starting"
           or "working" and every 60 while it is "waiting" (every 15 in any of the three while this
           machine keeps a stop, so its end is heard as fast), first at its first wake, in either
           reporter mode, wherever the machine's DevStride connection carries a key or the machine
           has a session reporter credential (with neither it is not run). The reporter keeps the answer on this machine
           (skills/build-item/scripts/session_stop.py), where hooks/stop-gate.py refuses the
           session's tool calls and prompts; an error or a timeout changes nothing, and its exit
           code 3 quiets the check for 30 minutes. A session with a person at it is never
           signalled: only the gate stops it, and a command it already started runs to its end.
           For an `unattended` session, once the kept stop is acknowledged, the keeper ends the
           session's process: only when its start time, known when recorded and read again now,
           still matches (a process id that may have been reused is never signalled), with SIGTERM
           (Claude Code ends its own commands and exits), on Windows with taskkill; it then sends
           `end` (reason `stopped`) and exits.
  send <event> <state> <session> <record> <sequence> <at>  (detached) runs the reporter once,
           holding the session's send lock so reports run one at a time, and only for the record
           that queued it (a record recreated since is another) and when its sequence number is
           above the last one sent: a report overtaken by a newer one is dropped, so an old `end`
           never follows a resumed session's `start`. Any event but SessionStart and UserPromptSubmit from an
           older process of the session, while a newer process holds it, does nothing. A repository's command runs from the
           repository root, through the shell; the built-in reporter runs with no arguments, from the
           repository root or the session's directory. Either runs at most 20 seconds, its exit code kept in
           the record with the mode that ran (`mode`: command | builtin). The built-in reporter's exit code 3
           (the server has no such tool, or refused the key) sets the record's `quiet` 30 minutes ahead, and
           its exit code 4, a timeout or an error (unreachable, busy) 2 minutes ahead; until then nothing is
           sent for the session, and exit code 0 removes it. A repository command's exit code never does. It exports
           PRESENCE_EVENT (start|beat|end), PRESENCE_STATE, PRESENCE_SESSION_ID, PRESENCE_MACHINE,
           PRESENCE_CHECKOUT (the repository root; empty outside a repository, as PRESENCE_BRANCH and
           PRESENCE_ITEM then are), PRESENCE_BRANCH, PRESENCE_ITEM (an item number the branch name carries,
           else empty), PRESENCE_PLUGIN_VERSION (the version of the code sending this report, hook
           or keeper, never one copied from the record), PRESENCE_INTERVAL_MINUTES, PRESENCE_END_REASON,
           PRESENCE_AT (when the hook or keeper queued the report, epoch milliseconds, always later
           than the session's previous report, so a repository can drop one older than it stored),
           PRESENCE_ACTIVE_AT (the session's last activity, epoch milliseconds; empty when unknown),
           PRESENCE_BUSY_SINCE (epoch milliseconds, digits only: the earliest start of a call still
           open, or the background mark when earlier or alone; empty when neither, and on `end`), and
           CLAUDE_CODE_SESSION_ID and CLAUDE_PID so the repository can resolve the session's name.

DEVSTRIDE_PRESENCE_MINUTE (seconds in a keeper minute, default 60) exists for the tests only.
Records: ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/presence/<session>.json (and the session's
three lock files), owner-only; another session's files untouched for 7 days are pruned at a new
session's start, each under its own lock; nothing is created for a session whose reporting is off
or whose machine has no key. A record holds `top` (the repository root, null outside one) and `dir`
(the directory the session works in); no record, marker or log ever holds a key. FAILS OPEN: every
hook exits 0 and prints nothing but the two no-key notices (a prompt hook's stdout becomes context),
whatever goes wrong. python3 and the standard library only.
"""
import calendar
import contextlib
import json
import os
import re
import secrets
import signal
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True  # never leave compiled files in the installed plugin
SCRIPT = os.path.realpath(__file__)
PLUGIN_ROOT = os.path.dirname(os.path.dirname(SCRIPT))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "skills/build-item/scripts"))
import claim_record  # noqa: E402  the one machine naming every claim uses
import portable  # noqa: E402  the calls that differ on Windows
import presence_settings  # noqa: E402  the one decision: off, the repository's command, or the built-in reporter
import session_stop  # noqa: E402  the stop a person asked for, kept by the built-in reporter's stop check

REPORTER = os.path.join(os.path.dirname(SCRIPT), "presence-report.py")
QUIET_REFUSED = 1800     # seconds the built-in reporter stays quiet after a definite refusal
QUIET_TRANSIENT = 120    # and after a failure that may pass
NOT_ON_FLEET = ("This session is not on the DevStride Fleet yet. It will be set up the first time you run a "
                "DevStride skill.")
# A prompt that runs a DevStride skill: it begins `/devstride:`, anchored like the session gate's test, and
# never `/ds:` (installed through the short marketplace entry, the skills still invoke as `/devstride:`).
# Never setup (connecting a full key is what it is for) or doctor (read-only), which report the missing
# key themselves.
SKILL_PROMPT = re.compile(r"\s*/devstride:(?!(?:setup|doctor)\b)[a-z][a-z0-9-]*\b")
REGISTER_STEPS = (
    "Before the DevStride skill this prompt runs: this machine's DevStride connection is a browser sign-in with no "
    "API key, so its sessions are not on the DevStride Fleet. Set up its session reporter credential first, once, "
    "unless you already tried in this session: (1) run `\"{python}\" \"{script}\" prepare`; it prints "
    "`FINGERPRINT: <hex>` and `MACHINE: <name>`. (2) Call the DevStride tool `register_session_reporter` with "
    "`machine` and `fingerprint` exactly as printed. (3) Run `\"{python}\" \"{script}\" finish --key-id <apiKey> "
    "--org-id <organizationId> --org-slug <organizationSlug> --username <username>` with the values of its answer. "
    "(4) Say this one line to the person: \"DevStride: this machine now reports its sessions to the Fleet with a "
    "reporting key named Session reporter \u00b7 <machine>. Revoke it any time under Profile Settings \u2192 API "
    "Keys.\" If a step fails (the script refuses, or the tool is missing or refuses), say instead, in one line, that "
    "the session reporter could not be set up and why, in the failing step's own words, and that /devstride:setup "
    "connect gives this machine a full key instead; do not try again in this session. Never print, ask for or pass "
    "on a secret: the script keeps it. Then run the skill as asked.")

SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
ITEM = re.compile(r"(?:^|[/_.-])(I[0-9]+)(?=$|[/_.-])")
BEAT_AFTER = 60          # a prompt re-sends when the last send is this old
CHANGE_AFTER = 30        # a state change within this of the last send waits for the next send
COMMAND_TIMEOUT = 20
KEEPER_TICK = 5          # seconds between a keeper's wakes; its own check runs every second one
STOP_CHECK_TICKS = {"starting": 3, "working": 3, "waiting": 12}  # wakes between stop checks: 15 s, 60 s
STOP_KEPT_TICKS = 3      # while this machine keeps a stop: 15 s whatever the state, so its end is heard as fast
STOP_CHECK_TIMEOUT = 25  # a stop check is at most two calls of 10 seconds
STOP_START_WAIT = 3      # the check a start makes for a stop kept while the session was ended: inside the hook's 5 s
KEEP = 7 * 24 * 3600
KEEPER_LOCK_TRIES = 20   # a new keeper tries its lock this many times, 0.1 s apart, before it leaves
STARTED_SLACK = 5        # seconds a process's reported start time may drift before it is another process
PAYLOAD_LIMIT = 4 * 1048576   # a prompt hook's payload carries the whole prompt
# Seconds in a keeper minute. Tests shorten it; nothing else sets DEVSTRIDE_PRESENCE_MINUTE.
try:
    MINUTE = max(0.01, float(os.environ.get("DEVSTRIDE_PRESENCE_MINUTE") or 60))
except ValueError:
    MINUTE = 60.0
STATES = ("starting", "working", "waiting", "ended")
EVENTS = ("start", "beat", "end")
FIRST = ("SessionStart", "UserPromptSubmit")  # the events that may start a report
# events that only update a session already reported
LATER = ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch", "Notification", "Stop", "StopFailure",
         "SessionEnd")
NOTICES = ("permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog", "elicitation_response",
           "elicitation_complete")
ANSWERED = ("elicitation_response", "elicitation_complete")  # the person answered an MCP prompt
QUESTIONS = ("AskUserQuestion", "ExitPlanMode")  # the main conversation asking its person
OPEN_LIMIT = 64          # open calls kept per session; the oldest is dropped beyond it
TRANSCRIPT_TAIL = 262144  # bytes at the end of the transcript the keeper reads to find an interrupt
INTERRUPTED = "[Request interrupted by user"  # how Claude Code's transcript opens the entry for an Esc
STATUS_LIMIT = 65536     # bytes of Claude Code's own session status file the keeper reads
ISO_TIME = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z$")
TOOL_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")


def cache_dir():
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "devstride-plugin")


def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != portable.uid():
        raise OSError("untrusted directory")
    return path


def records_path():
    return os.path.join(cache_dir(), "presence")


def records_dir():
    """The records directory, created owner-only when missing: only once a report is due."""
    return private_dir(os.path.join(private_dir(cache_dir()), "presence"))


def read_json(path, limit=1048576):
    """A regular file we (or root) own, opened without following a symlink; None on any doubt."""
    try:
        fd = os.open(path, os.O_RDONLY | portable.flags("O_NONBLOCK", "O_NOFOLLOW"))
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid not in (portable.uid(), 0) or info.st_size > limit:
            return None
        return json.loads(os.read(fd, limit + 1))
    except Exception:
        return None
    finally:
        os.close(fd)


def write_atomic(directory, name, payload):
    data = (json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n").encode()
    temporary = os.path.join(directory, ".%s.%s.tmp" % (name, secrets.token_hex(8)))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | portable.flags("O_NOFOLLOW"), 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    portable.replace(temporary, os.path.join(directory, name))


def load(sid):
    """The session's record, or None; read-only, so it never creates a directory."""
    record = read_json(os.path.join(records_path(), sid + ".json"), limit=65536)
    return record if isinstance(record, dict) and record.get("schema") == 1 else None


def save(sid, record):
    write_atomic(records_dir(), sid + ".json", record)


def stale(path, now):
    try:
        info = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and info.st_uid == portable.uid() and now - info.st_mtime > KEEP


def prune(own, now):
    """Remove other sessions' files untouched for KEEP. A record or lock goes only while its lock is
    held and it is still stale, so a session that comes back at that moment keeps its files."""
    directory = records_path()
    # records before locks: pruning a record takes its state lock, which would recreate a lock pruned first
    for name in sorted(os.listdir(directory), key=lambda n: not n.endswith(".json")):
        path = os.path.join(directory, name)
        if not stale(path, now):
            continue
        try:
            if name.startswith("."):
                os.unlink(path)  # a temporary file left by a killed writer
                continue
            if name.endswith(".lock"):
                sid, kind = name[:-5].rsplit(".", 1)
            elif name.endswith(".json"):
                sid, kind = name[:-5], "state"
            else:
                continue
            if sid == own or not SESSION_ID.match(sid) or kind not in ("state", "send", "keeper"):
                continue
            fd = lock(sid, kind, False, touch=False)
            if fd is None:
                continue
            try:
                if stale(path, now):
                    os.unlink(path)
            finally:
                os.close(fd)
        except (OSError, ValueError):
            pass


def repo_top(start):
    """The checkout's root: the nearest directory holding .git (a directory or a worktree's file)."""
    here = os.path.realpath(start)
    while True:
        if os.path.exists(os.path.join(here, ".git")):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            return None
        here = parent


_READINESS = []  # the last readiness word this process resolved, for the no-key notices


def connection_ready(top, place):
    """Whether the machine's DevStride connection carries a key, for a session in this place. The
    resolver is imported only here: a hook in a repository that names a command, or a switched-off
    one, never loads it (a keeper does, for its stop check)."""
    try:
        import devstride_connection  # the one place the machine's DevStride key is found
        word = devstride_connection.readiness(os.environ, devstride_connection.config_file(os.environ),
                                              devstride_connection.project_places(top, place), reporter=True)
        _READINESS[:] = [word]
        return word in devstride_connection.READY_WORDS
    except Exception:
        return False


def decide(top, place, check_key=True):
    """(the effective settings or None, the fixed reason word) for a session whose repository root
    is `top` (None outside one) and whose directory is `place`."""
    top = top if isinstance(top, str) and top else None
    place = place if isinstance(place, str) and place else top
    ready = (lambda: connection_ready(top, place)) if check_key else None
    return presence_settings.effective(top, read_json, os.environ, ready)


def settings(top, place, check_key=True):
    """How this session reports: {"mode", "command", "intervalMinutes"}, or None when nothing runs."""
    return decide(top, place, check_key)[0]


def marker_path():
    """Where an earlier version kept its once-per-machine note; removed when found."""
    return os.path.join(cache_dir(), "presence-no-key")


def no_key_notice(event, reason, prompt=""):
    """The only things this hook prints, both only when there is truly no key (an address that is
    not DevStride's, or a file that cannot be read safely, is doctor's to explain): at every
    SessionStart, a line shown to the person; at a prompt that runs a DevStride skill, the steps
    that register this machine's session reporter credential, for the model."""
    try:
        if os.path.lexists(marker_path()):
            os.unlink(marker_path())
    except OSError:
        pass
    if reason != "no-key" or _READINESS[-1:] != ["no-key"]:
        return
    if event == "SessionStart":
        notice = {"systemMessage": NOT_ON_FLEET}
    elif event == "UserPromptSubmit" and isinstance(prompt, str) and SKILL_PROMPT.match(prompt):
        script = os.path.join(PLUGIN_ROOT, "skills/build-item/scripts", "reporter_credential.py")
        notice = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext":
                  REGISTER_STEPS.format(python=sys.executable or "python3", script=script)}}
    else:
        return
    try:
        sys.stdout.write(json.dumps(notice) + "\n")
        sys.stdout.flush()
    except OSError:
        pass


_VERSION = []


def own_version():
    """The version of the plugin this file belongs to, read once per process: the code actually
    running. Hooks run the loaded plugin's copy, so a hook records the loaded version, and a keeper
    or send reports its own, never one copied from the record. "" when unreadable."""
    if not _VERSION:
        manifest = read_json(os.path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json"))
        version = manifest.get("version") if isinstance(manifest, dict) and manifest.get("name") == "devstride" else None
        _VERSION.append(version if isinstance(version, str) and SEMVER.match(version) else "")
    return _VERSION[0]


alive = portable.alive  # never os.kill(pid, 0) on Windows, where it sends a Ctrl+C


def env_owner():
    value = os.environ.get("CLAUDE_PID", "")
    return int(value) if value.isdigit() and alive(int(value)) else 0


def owner_pid():
    """The session's Claude Code process: CLAUDE_PID when Claude Code exports it, else the parent of
    the shell that runs this hook. 0 when neither can be found."""
    if env_owner():
        return env_owner()
    pid = portable.parent_of(os.getppid())
    # Windows: Git for Windows' bash.exe is a launcher that starts the real bash as its child
    for _ in range(3 if portable.IS_WINDOWS else 0):
        if windows_image(pid) not in ("bash", "sh"):
            break
        pid = portable.parent_of(pid)
    return pid if alive(pid) else 0


def windows_image(pid):
    """A Windows process's program name, lower case without .exe; "" when unknown (this file's own
    small helper: the shared one gives a parent's id, not its name)."""
    try:
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.OpenProcess.restype = wintypes.HANDLE
        k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        k32.QueryFullProcessImageNameW.argtypes = (wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                                   ctypes.POINTER(wintypes.DWORD))
        k32.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return ""
        try:
            size = wintypes.DWORD(1024)
            name = ctypes.create_unicode_buffer(size.value)
            if not k32.QueryFullProcessImageNameW(handle, 0, name, ctypes.byref(size)):
                return ""
        finally:
            k32.CloseHandle(handle)
    except Exception:
        return ""
    base = name.value.replace("\\", "/").rsplit("/", 1)[-1].lower()
    return base[:-4] if base.endswith(".exe") else base


def started(pid):
    """A process's start time in epoch seconds, so a reused process id is told apart; 0 unknown.
    Printed in UTC, so a long-lived keeper and a fresh hook read it alike whatever the zone."""
    return portable.started(pid)


def unattended(owner):
    """Whether the session runs with no person at it, read at its start: DEVSTRIDE_UNATTENDED=1, an
    SDK entry point (CLAUDE_CODE_ENTRYPOINT starts with `sdk`), or `-p` / `--print` among the
    session process's own arguments (each argument whole, so a prompt that mentions -p is not
    one). Only such a session's process is ever ended by a stop; any doubt reads as a person
    being there."""
    if os.environ.get("DEVSTRIDE_UNATTENDED") == "1" or (os.environ.get("CLAUDE_CODE_ENTRYPOINT") or "").startswith("sdk"):
        return True
    for argument in portable.arguments(owner)[1:]:
        if argument == "--":
            break  # what follows is the prompt
        if argument in ("-p", "--print"):
            return True
    return False


def lock(sid, kind, block_until_free, touch=True):
    """An open, flock-held lock file for this session, or None when another process holds it (and
    block_until_free is False). The lock lives as long as the returned descriptor. A lock whose file
    was unlinked while we waited is a lock on nothing, so it is taken again on the file now there."""
    path = os.path.join(records_dir(), "%s.%s.lock" % (sid, kind))
    for _ in range(5):
        fd = os.open(path, os.O_RDWR | os.O_CREAT | portable.flags("O_NOFOLLOW"), 0o600)
        try:
            held = portable.lock(fd, block_until_free)
        except OSError:
            held = False
        if not held:
            os.close(fd)
            return None
        try:
            same = os.fstat(fd).st_ino == os.lstat(path).st_ino
        except OSError:
            same = False
        if same:
            if touch:
                portable.touch(fd, path)
            return fd
        os.close(fd)
    return None


@contextlib.contextmanager
def state_lock(sid):
    """Held around every read-modify-write of the record, never while the command runs."""
    fd = lock(sid, "state", True)
    if fd is None:
        raise OSError("state lock")
    try:
        yield
    finally:
        os.close(fd)


def queue(record, now):
    """Mark a report as queued now (the state lock is held): its sequence number, and its time in
    milliseconds, always later than the session's previous report."""
    sequence = int(record.get("queued") or 0) + 1
    at = max(int(now * 1000), int(record.get("at") or 0) + 1)
    record.update({"queued": sequence, "at": at, "sent": round(now, 3), "reported": record.get("state")})
    return sequence, at


def keeper_running(sid):
    fd = lock(sid, "keeper", False)
    if fd is None:
        return True
    os.close(fd)
    return False


def retire_keepers(sid):
    """End THIS session's keeper when it runs another copy of this script: one started by a plugin
    version from before keepers checked the version, which would otherwise run (and report without
    the busy mark) until the session ends. Only this user's processes whose command line ends with
    `/hooks/presence.py keeper <this session>`, never this file's own: another session's keeper is
    never touched. Waits up to half a second for its lock to be released (with `ps`, well inside the
    hook's own limit). Returns whether it ended one. Never on Windows: no keeper from before this
    check ever ran there, and its `ps` lists no command lines."""
    if portable.IS_WINDOWS:
        return False
    try:
        out = subprocess.run(["ps", "-ww", "-U", str(portable.uid()), "-o", "pid=,command="], capture_output=True,
                             text=True, timeout=1)
    except Exception:
        return False
    tail, own = "/hooks/presence.py keeper " + sid, " %s keeper %s" % (SCRIPT, sid)
    ended = False
    for line in out.stdout.splitlines():
        pid, _, command = line.strip().partition(" ")
        command = command.strip()
        if pid.isdigit() and int(pid) != os.getpid() and command.endswith(tail) and not command.endswith(own):
            try:
                os.kill(int(pid), signal.SIGTERM)
                ended = True
            except OSError:
                pass
    for _ in range(10 if ended else 0):
        if not keeper_running(sid):
            break
        time.sleep(0.05)
    return ended


def spawn(*args):
    portable.spawn_detached([sys.executable, SCRIPT] + list(args), stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)


def branch_of(top):
    try:
        out = subprocess.run(["git", "-C", top, "symbolic-ref", "--short", "-q", "HEAD"],
                             capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=3)
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def active_at(record):
    value = record.get("activeAt")
    return str(value) if isinstance(value, int) and not isinstance(value, bool) and value > 0 else ""


def stamp(value):
    """A positive integer epoch-milliseconds value, else 0."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else 0


def open_calls(record):
    """The record's open calls, {tool_use_id: start in ms}, with anything malformed left out."""
    calls = record.get("tools")
    if not isinstance(calls, dict):
        return {}
    return {key: stamp(value) for key, value in calls.items()
            if isinstance(key, str) and TOOL_ID.match(key) and stamp(value)}


def busy_since(record):
    """The earliest start of an open call, or the background mark; "" when neither."""
    marks = list(open_calls(record).values()) + ([stamp(record.get("background"))] if stamp(record.get("background")) else [])
    return str(min(marks)) if marks else ""


def background_running(payload):
    """Whether a finished turn left its own background work running (Stop's background_tasks). A
    teammate is left out: its entry reads `running` for the whole session, idle or not, and a busy
    teammate's own tool calls report it."""
    tasks = payload.get("background_tasks")
    return isinstance(tasks, list) and any(isinstance(t, dict) and t.get("status") == "running"
                                           and t.get("type") != "teammate" for t in tasks)


def epoch_ms(text):
    """An ISO 8601 UTC time, as Claude Code stamps a transcript entry, in epoch milliseconds; else 0."""
    match = ISO_TIME.match(text) if isinstance(text, str) else None
    if not match:
        return 0
    try:
        seconds = calendar.timegm(time.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return 0
    return seconds * 1000 + int((match.group(2) or "0").ljust(3, "0")[:3])


def interrupted(path):
    """When the turn this transcript ends on was interrupted by its person, in epoch milliseconds;
    0 when it was not, or on any doubt. Claude Code fires no hook for an interrupt, but writes a
    user entry whose one text block starts with INTERRUPTED. It counts only as the main
    conversation's LAST user or assistant entry: anything said after it means the session moved on.
    Only the file's last TRANSCRIPT_TAIL bytes are read, from a regular file the user (or root) owns."""
    if not isinstance(path, str) or not path:
        return 0
    try:
        fd = os.open(path, os.O_RDONLY | portable.flags("O_NONBLOCK", "O_NOFOLLOW"))
    except (OSError, ValueError):
        return 0
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid not in (portable.uid(), 0):
            return 0
        start = max(0, info.st_size - TRANSCRIPT_TAIL)
        lines = portable.pread(fd, TRANSCRIPT_TAIL, start).split(b"\n")
    except OSError:
        return 0
    finally:
        os.close(fd)
    for line in reversed(lines[1:] if start else lines):  # the window's first line may be cut
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except Exception:
            return 0  # an entry still being written: the next check reads it whole
        if not isinstance(entry, dict) or entry.get("type") not in ("user", "assistant") or entry.get("isSidechain"):
            continue  # the session's own bookkeeping, or a helper agent's conversation
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        content = message.get("content")
        if (entry["type"] == "user" and isinstance(content, list) and len(content) == 1 and isinstance(content[0], dict)
                and isinstance(content[0].get("text"), str) and content[0]["text"].startswith(INTERRUPTED)):
            return epoch_ms(entry.get("timestamp"))
        return 0
    return 0


def config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def went_idle(sid, owner):
    """When Claude Code marked this session idle, in epoch milliseconds; 0 when it is not idle, or on
    any doubt. An Esc pressed while the model is still thinking writes nothing to the transcript and
    fires no hook, but Claude Code's own status file for the session's process
    (<config>/sessions/<pid>.json) turns from "busy" to "idle" at once. It counts only for this
    session and this process, from a regular file the user (or root) owns."""
    if isinstance(owner, bool) or not isinstance(owner, int) or owner <= 0:
        return 0
    try:
        fd = os.open(os.path.join(config_dir(), "sessions", "%d.json" % owner), os.O_RDONLY | portable.flags("O_NONBLOCK", "O_NOFOLLOW"))
    except (OSError, ValueError):
        return 0
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid not in (portable.uid(), 0) or info.st_size > STATUS_LIMIT:
            return 0
        data = json.loads(portable.pread(fd, STATUS_LIMIT, 0))
    except Exception:
        return 0
    finally:
        os.close(fd)
    if not isinstance(data, dict) or data.get("sessionId") != sid or data.get("pid") != owner or data.get("status") != "idle":
        return 0
    at = data.get("statusUpdatedAt")
    return at if isinstance(at, int) and not isinstance(at, bool) and at > 0 else 0


def transition(event, payload, record, now_ms):
    """Apply one hook event to the record (the state lock is held): its open calls, background mark
    and failed-turn flag. Returns (the new state, or None to keep the state; whether it is a sign of
    the session's own activity). "Interrupt" is no hook event: the keeper applies it when the
    transcript shows the person interrupted the turn, which ends it as a Stop with nothing running does."""
    calls = open_calls(record)
    callers = record.get("callers") if isinstance(record.get("callers"), dict) else {}
    asking = record.get("asking") if isinstance(record.get("asking"), str) else ""
    call = payload.get("tool_use_id") if isinstance(payload.get("tool_use_id"), str) else ""
    main = not payload.get("agent_id")
    agent = "" if main else str(payload.get("agent_id"))[:128]
    state, active = None, event != "SessionEnd"
    if event in ("SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Interrupt") or (
            event == "Notification" and payload.get("notification_type") == "idle_prompt"):
        asking = ""
    if event in FIRST:
        calls = {}
        record.update({"background": 0, "failed": False, "prompted": now_ms})
        if isinstance(payload.get("transcript_path"), str) and 0 < len(payload["transcript_path"]) <= 4096:
            record["transcript"] = payload["transcript_path"]
        state = "starting" if event == "SessionStart" else "working"
    elif event == "PreToolUse":
        if payload.get("tool_name") in QUESTIONS and main:
            state = "waiting"  # a question or a plan approval: the person's turn
            asking = call if TOOL_ID.match(call) else "-"
        else:
            state = None if asking else "working"
            if TOOL_ID.match(call):
                calls[call] = now_ms
                if agent:
                    callers[call] = agent
                for oldest in sorted(calls, key=calls.get)[:max(0, len(calls) - OPEN_LIMIT)]:
                    del calls[oldest]
    elif event in ("PostToolUse", "PostToolUseFailure"):
        calls.pop(call, None)
        if asking and (call == asking or (asking == "-" and main)):
            asking = ""  # the person answered
        state = None if asking else "working"
    elif event == "PostToolBatch":
        listed = payload.get("tool_calls") if isinstance(payload.get("tool_calls"), list) else []
        listed = {c.get("tool_use_id") for c in listed if isinstance(c, dict) and isinstance(c.get("tool_use_id"), str)}
        calls = {key: start for key, start in calls.items() if key not in listed and callers.get(key, "") != agent}
        if asking and (asking in listed or (asking == "-" and main)):
            asking = ""
        state = None if asking else "working"
    elif event == "Notification":
        if payload.get("notification_type") == "idle_prompt":
            calls = {}  # an interrupted call never closes
            if stamp(record.get("background")) or record.get("failed") is True:
                active = False  # the session is waiting on its own work, or cannot continue
            else:
                state = "waiting"
        elif payload.get("notification_type") in ANSWERED:
            state = None if asking else "working"
        else:
            state = "waiting"  # a permission or elicitation prompt
    elif event in ("Stop", "Interrupt"):
        calls = {}
        record["failed"] = False
        if background_running(payload):
            state = "working"
            record["background"] = now_ms
        else:
            state = "waiting"
            record["background"] = 0
    elif event == "StopFailure":
        calls = {}
        record.update({"background": 0, "failed": True})
        active = False  # a usage limit is no sign of life: it must still read as idle while working
    elif event == "SessionEnd":
        state = "ended"
    record["tools"] = calls
    record["callers"] = {key: str(callers[key])[:128] for key in calls if key in callers}
    record["asking"] = asking
    return state, active


def item_of(branch):
    match = ITEM.search(branch or "")
    return match.group(1) if match else ""


def report_job(sid, record, event, state, at):
    """What one report runs: (mode, the command or argument list, its working directory, its
    environment), or None when reporting is off for the record's place. The built-in reporter gets
    no arguments and nothing in its environment beyond what a repository's command gets: it finds
    the key itself, so no key can ever show in a process list."""
    top = record.get("top") if isinstance(record.get("top"), str) and record.get("top") else None
    place = record.get("dir") if isinstance(record.get("dir"), str) and record.get("dir") else top
    conf = settings(top, place)
    if not conf:
        return None
    branch = branch_of(top) if top else ""
    env = dict(os.environ)
    env.update({
        "PRESENCE_EVENT": event, "PRESENCE_STATE": state,
        "PRESENCE_SESSION_ID": sid, "PRESENCE_MACHINE": claim_record.machine_name(),
        "PRESENCE_CHECKOUT": top or "", "PRESENCE_BRANCH": branch, "PRESENCE_ITEM": item_of(branch),
        "PRESENCE_PLUGIN_VERSION": own_version(),  # the code sending this report, never the record's
        "PRESENCE_INTERVAL_MINUTES": str(conf["intervalMinutes"]),
        "PRESENCE_END_REASON": str(record.get("reason") or "") if event == "end" else "",
        "PRESENCE_AT": str(at), "PRESENCE_ACTIVE_AT": active_at(record),
        "PRESENCE_BUSY_SINCE": busy_since(record) if event != "end" else "", "CLAUDE_CODE_SESSION_ID": sid,
    })
    if record.get("owner"):
        env["CLAUDE_PID"] = str(record["owner"])
    if conf["mode"] == "command":
        return "command", conf["command"], top, env
    cwd = next((d for d in (place, top) if d and os.path.isdir(d)), None)  # where the key was looked for
    return "builtin", [sys.executable, REPORTER], cwd, env


def quiet_until(record):
    value = record.get("quiet")
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def run_command(sid, record, event, state, at):
    """Run one report. Returns (its exit code, "timeout" or "error", or None when nothing ran; the
    mode that ran, or None when reporting is off)."""
    job = report_job(sid, record, event, state, at)
    if not job:
        return None, None
    mode, command, cwd, env = job
    if mode == "builtin" and time.time() < quiet_until(record):
        return None, mode  # the server refused or could not be reached a moment ago: not again yet
    try:
        # a repository's command runs through the shell: /bin/sh, as shell=True would, or Git for Windows' bash
        child = subprocess.Popen(portable.shell(command) if mode == "command" else command, cwd=cwd, env=env,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 **portable.group())
        try:
            return child.wait(timeout=COMMAND_TIMEOUT), mode
        except subprocess.TimeoutExpired:
            portable.kill_tree(child)
            child.wait()
            return "timeout", mode
    except Exception:
        return "error", mode


def send(event, state, sid, incarnation, sequence, at):
    """Run the session's reporter once: one report at a time, only for the record that queued it,
    and only when no newer report has already been sent."""
    if event not in EVENTS or state not in STATES:
        return
    fd = lock(sid, "send", True)
    if fd is None:
        return
    try:
        with state_lock(sid):
            record = load(sid)
            if not record or record.get("id") != incarnation or sequence <= int(record.get("done") or 0):
                return  # the record was replaced, or a newer report for this session already ran
        code, mode = run_command(sid, record, event, state, at)
        with state_lock(sid):
            latest = load(sid)
            if latest and latest.get("id") == incarnation:  # never recreate a record removed meanwhile
                latest["done"] = max(sequence, int(latest.get("done") or 0))
                if code is not None:
                    latest["mode"] = mode  # the reporter that ran; a skipped report says nothing
                    latest["last"] = {"event": event, "exit": code, "at": round(time.time(), 3)}
                    if mode == "builtin":  # a repository command's exit code never quiets anything
                        if code == 0:
                            latest.pop("quiet", None)
                        else:
                            latest["quiet"] = round(time.time() + (QUIET_REFUSED if code == 3 else QUIET_TRANSIENT), 3)
                save(sid, latest)
    finally:
        os.close(fd)


def read_payload():
    try:
        payload = json.loads(portable.stdin_text(PAYLOAD_LIMIT) or "{}")
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def hook():
    payload = read_payload()
    if not payload:
        return
    event, sid = payload.get("hook_event_name"), payload.get("session_id")
    if event not in FIRST + LATER or not isinstance(sid, str) or not SESSION_ID.match(sid):
        return
    if event == "Notification" and payload.get("notification_type") not in NOTICES:
        return  # only a prompt waiting on the person, or the idle prompt, says anything about the session
    if event == "SessionStart" and payload.get("source") == "compact":
        return  # the session carries on after a compaction
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    top = repo_top(cwd)
    place = os.path.realpath(cwd)  # the directory the session works in, inside a repository or not
    here, reason = decide(top, place)
    no_key_notice(event, reason, payload.get("prompt"))
    peek = load(sid)
    if not here and not (peek and settings(peek.get("top"), peek.get("dir"))):
        return  # nothing to report, and nothing written
    # The one later event that may open a record: the session's start and prompt came before the
    # machine had any key, and this session has since registered the session reporter credential
    # (the registration steps run inside a turn). Without it the session stays off the Fleet until
    # its next prompt, and a one-prompt run never shows at all.
    opens = event in LATER and event != "SessionEnd" and peek is None and bool(here) \
        and _READINESS[-1:] == ["session-reporter"]
    if event in LATER and not opens and (peek is None or peek.get("state") == "ended"):
        return  # never reported here, or already ended
    version = own_version()
    # Once per session and version, when a keeper runs that this version did not start: a keeper from
    # before keepers checked the version never leaves by itself, so it is ended here (and a newer
    # one's own check would only catch it at its next beat).
    swept = bool(peek) and peek.get("state") != "ended" and peek.get("swept") != version and keeper_running(sid)
    retired = swept and retire_keepers(sid)  # the keeper it ended may have dropped a queued report
    mine = int(os.environ["CLAUDE_PID"]) if os.environ.get("CLAUDE_PID", "").isdigit() else 0
    # every `ps` runs here, before the state lock is taken
    owner = owner_pid() if event in FIRST or opens else 0
    owner_started = started(owner) if owner else 0
    alone = event == "SessionStart" and bool(owner) and unattended(owner)
    with state_lock(sid):
        now = time.time()
        record = load(sid)
        was, why = decide(record.get("top"), record.get("dir")) if record else (None, None)
        # a repository whose command reported this session, and whose config cannot be read just now
        # (a merge in progress), still holds it: nothing is sent, and the built-in reporter does not take over
        held = bool(record) and record.get("mode") == "command" and why == "config-unreadable"
        if not here and not was:
            return
        if held and here:
            return
        if not here or (here["mode"] == "builtin" and was and was["mode"] == "command"):
            # moved to a place where reporting is off, or away from a repository whose own command
            # reports this session to a place that names none: keep reporting under the one it came from
            top, place = record.get("top"), record.get("dir") or record.get("top")
        fresh = record is None
        previous = None if fresh else record.get("state")
        if event in LATER:
            if (fresh and not opens) or previous == "ended":
                return
            if not fresh and mine and record.get("owner") not in (0, None, mine) and alive(record.get("owner")):
                return  # from an older process of this session, which a newer one has since resumed
        if fresh:
            record = {"schema": 1, "top": top, "dir": place, "state": None, "sent": 0, "owner": 0}
        if not record.get("id"):
            record["id"] = secrets.token_hex(6)  # this record's incarnation: sends are bound to it
        moved = not fresh and record.get("top") != top
        state, active = transition(event, payload, record, int(now * 1000))
        sent, state = record.get("sent") or 0, state or previous or ("working" if fresh else None)
        if fresh and opens and isinstance(payload.get("transcript_path"), str) \
                and 0 < len(payload["transcript_path"]) <= 4096:
            record["transcript"] = payload["transcript_path"]  # the keeper reads it for an interrupt
        record.update({"top": top, "dir": place, "state": state, "version": version or record.get("version") or ""})
        if active:
            record["activeAt"] = int(now * 1000)  # the session's last sign of life: start, prompt, tool call, stop
        if owner and (event == "SessionStart" or owner_started or owner != record.get("owner")):
            # re-read on every start and prompt; a start whose look-up failed keeps no old start time
            if event == "SessionStart" or owner != record.get("owner"):
                record["unattended"] = alone  # read at a start, for the process that started
            record.update({"owner": owner, "ownerStarted": owner_started})
        if event == "SessionEnd":
            record["reason"] = str(payload.get("reason") or "")
            verb = "end"
        elif event == "SessionStart" or fresh or previous == "ended":
            verb = "start"
        elif event == "UserPromptSubmit" and (now - sent >= BEAT_AFTER or moved):
            verb = "beat"
        elif (state != record.get("reported") or moved) and now - sent >= CHANGE_AFTER:
            verb = "beat"
        elif retired:
            verb = "beat"  # a report from this version now, not at the replacement's first interval
        else:
            verb = None
        sequence, at = queue(record, now) if verb else (0, 0)
        # any event starts a keeper when none runs: one that left for a version change is replaced
        # by this, the loaded version, at the session's next hook event
        start_keeper = state != "ended" and bool(record.get("owner")) and not keeper_running(sid)
        if swept or start_keeper:
            record["swept"] = version  # no keeper of another version is left for this one to end
        save(sid, record)
        if verb:
            spawn("send", verb, state, sid, record["id"], str(sequence), str(at))
        if start_keeper:
            spawn("keeper", sid)
    if fresh and event == "SessionStart":
        prune(sid, now)
    if event == "SessionStart" and session_stop.read(sid) is not None:
        # started again with a stop still kept: no keeper ran while the session was ended to hear a
        # person let it continue, so ask now, before its first prompt reaches the stop gate; a slower
        # answer is left to land, so the next start meets it
        stop_check(sid, record, STOP_START_WAIT, let_finish=True)


def replaced(record):
    """Whether the session's process id now belongs to another process: only a known start time
    more than a few seconds off counts (a stepped clock shifts what `ps` reports), never a failed
    look-up."""
    was = record.get("ownerStarted")
    if isinstance(was, bool) or not isinstance(was, int) or was <= 0:
        return False
    now = started(record.get("owner"))
    return bool(now and abs(now - was) > STARTED_SLACK)


def confirmed(record):
    """Whether the session's process is still the one the record names: its start time, known when
    recorded and read again now, within a few seconds. The strict twin of replaced(): a look-up
    that fails confirms nothing, so a process id that may have been reused is never signalled."""
    was, owner = record.get("ownerStarted"), record.get("owner")
    if (isinstance(was, bool) or not isinstance(was, int) or was <= 0
            or isinstance(owner, bool) or not isinstance(owner, int) or owner <= 1):
        return False
    now = started(owner)
    return bool(now) and abs(now - was) <= STARTED_SLACK


def stop_check(sid, record, wait=STOP_CHECK_TIMEOUT, let_finish=False):
    """Ask DevStride once whether a person stopped this session: the built-in reporter's stop-sync,
    which keeps the answer on this machine. It runs in either reporter mode, wherever the machine's
    DevStride connection carries a key or the machine has a session reporter credential. Returns the
    reporter's exit code; None when it did not run (neither), could not be started or did not finish within `wait` seconds. A reporter still running
    then is ended, which changes nothing, unless `let_finish` leaves it to keep its answer when it
    comes (it runs in a group of its own, its output discarded)."""
    top = record.get("top") if isinstance(record.get("top"), str) and record.get("top") else None
    place = record.get("dir") if isinstance(record.get("dir"), str) and record.get("dir") else top
    if not connection_ready(top, place):
        return None
    env = dict(os.environ)
    env.update({"PRESENCE_SESSION_ID": sid, "PRESENCE_CHECKOUT": top or "", "CLAUDE_CODE_SESSION_ID": sid})
    cwd = next((d for d in (place, top) if d and os.path.isdir(d)), None)  # where the key was looked for
    try:
        child = subprocess.Popen([sys.executable, REPORTER, "stop-sync"], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **portable.group())
        try:
            return child.wait(timeout=wait)
        except subprocess.TimeoutExpired:
            if not let_finish:
                portable.kill_tree(child)
                child.wait()
            return None
    except Exception:
        return None


def end_stopped(sid, peek):
    """End an unattended session a person stopped (the state lock is held): its process is asked
    to end, and the record reads ended, reason `stopped`. Only for the process `peek` named, whose
    start time the caller has just confirmed, and never for a session with a person at it. Returns
    the queued `end` (the record's id, its sequence number and time), or None when nothing was done."""
    record = load(sid)
    if (not record or record.get("state") == "ended" or record.get("unattended") is not True
            or record.get("owner") != peek.get("owner") or record.get("ownerStarted") != peek.get("ownerStarted")
            or not portable.terminate(record.get("owner"))):
        return None
    record.update({"state": "ended", "reason": "stopped"})
    job = (record["id"],) + queue(record, time.time())
    save(sid, record)
    return job


def interrupt(record, peek, mark, idle=False):
    """Apply an interrupt the transcript showed at `mark` (the state lock is held): only to a session
    still working, on the transcript that was read, and only one later than the session's last
    start or prompt and than the last interrupt applied. With `idle`, `mark` is when Claude Code's
    status file turned idle: it counts only for the process that was read, a session with no
    background work left running and no failed turn, and only when nothing happened since.
    Returns whether the record changed."""
    if (not mark or record.get("state") != "working" or record.get("transcript") != peek.get("transcript")
            or mark <= max(stamp(record.get("prompted")), stamp(record.get("interrupt")))):
        return False
    if idle and (record.get("owner") != peek.get("owner") or stamp(record.get("background"))
                 or record.get("failed") is True or mark <= stamp(record.get("activeAt"))):
        return False
    state, _ = transition("Interrupt", {}, record, mark)
    record.update({"state": state, "interrupt": mark, "activeAt": max(stamp(record.get("activeAt")), mark)})
    return True


def keeper(sid):
    if load(sid) is None:
        return  # no session to keep
    # A check that a keeper runs (keeper_running, here or in a test) holds the lock for a moment, so
    # one refused attempt is not proof: try for up to two seconds. A real keeper holds the lock for
    # as long as it runs, so a second keeper still leaves, a little later.
    fd = None
    for attempt in range(KEEPER_LOCK_TRIES):
        fd = lock(sid, "keeper", False)
        if fd is not None:
            break
        if attempt + 1 < KEEPER_LOCK_TRIES:
            time.sleep(0.1)
    if fd is None:
        return  # another keeper runs for this session
    tick = KEEPER_TICK * MINUTE / 60
    version = own_version()
    path = os.path.join(records_path(), "%s.keeper.lock" % sid)
    ticks, unchecked, quiet = 0, max(STOP_CHECK_TICKS.values()), 0  # the first stop check is due at the first wake
    try:
        while fd is not None:
            time.sleep(tick)
            ticks, unchecked, quiet = ticks + 1, unchecked + 1, max(0, quiet - 1)
            peek = load(sid) or {}
            every = STOP_CHECK_TICKS.get(peek.get("state"))
            if every and session_stop.read(sid) is not None:
                every = STOP_KEPT_TICKS  # a stopped session mostly waits: "allow to continue" is heard within 15 s
            if every and unchecked >= every and not quiet:
                unchecked = 0
                if stop_check(sid, peek) == 3:
                    quiet = QUIET_REFUSED // KEEPER_TICK  # the server has no such tool, or refused the key
                kept = session_stop.read(sid)
                # a stop the server knows this machine heard, for a session with no person at it
                if kept and kept.get("acknowledged") is True and peek.get("unattended") is True and confirmed(peek):
                    with state_lock(sid):
                        job = end_stopped(sid, peek)
                        if job:
                            os.close(fd)  # released under the state lock, as every exit is
                            fd = None
                    if job:
                        send("end", "ended", sid, job[0], job[1], job[2])
                        continue
            if ticks % 2:
                continue  # the check below runs every second wake
            portable.touch(fd, path)
            peek = load(sid) or {}
            conf = settings(peek.get("top"), peek.get("dir"))
            due = bool(conf) and time.time() - (peek.get("sent") or 0) >= conf["intervalMinutes"] * MINUTE
            reused = due and replaced(peek)  # `ps` runs outside the state lock
            mark = interrupted(peek.get("transcript")) if peek.get("state") == "working" else 0  # so does this read
            idle = went_idle(sid, peek.get("owner")) if peek.get("state") == "working" and not mark else 0  # and this
            job = None
            with state_lock(sid):
                record = load(sid)
                conf = settings(record.get("top"), record.get("dir")) if record else None
                # the session's hooks now run another version: leave, and its next hook event
                # starts a keeper of that version
                moved_on = bool(record and version and record.get("version") not in (None, "", version))
                if not conf or record.get("state") == "ended" or moved_on:
                    os.close(fd)  # released under the state lock: a resume then starts a new keeper
                    fd = None
                    continue
                owner, now = record.get("owner"), time.time()
                due = now - (record.get("sent") or 0) >= conf["intervalMinutes"] * MINUTE
                same = owner == peek.get("owner") and record.get("ownerStarted") == peek.get("ownerStarted")
                if not alive(owner) or (reused and same):
                    record.update({"state": "ended", "reason": "gone"})
                    job = ("end", "ended") + queue(record, now)
                    save(sid, record)
                    os.close(fd)
                    fd = None
                else:
                    noted = interrupt(record, peek, mark) or interrupt(record, peek, idle, idle=True)
                    held = record.get("state") != record.get("reported") and now - (record.get("sent") or 0) >= CHANGE_AFTER
                    if due or held:
                        job = ("beat", record["state"]) + queue(record, now)
                    if job or noted:
                        save(sid, record)
            if job:
                send(job[0], job[1], sid, record["id"], job[2], job[3])
    finally:
        if fd is not None:
            os.close(fd)


def main(argv):
    try:
        if argv[:1] == ["hook"]:
            hook()
        elif argv[:1] == ["keeper"] and len(argv) == 2 and SESSION_ID.match(argv[1]):
            keeper(argv[1])
        elif (argv[:1] == ["send"] and len(argv) == 7 and SESSION_ID.match(argv[3]) and argv[5].isdigit()
              and argv[6].isdigit()):
            send(argv[1], argv[2], argv[3], argv[4], int(argv[5]), int(argv[6]))
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
