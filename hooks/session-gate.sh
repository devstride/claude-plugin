#!/bin/bash
# hooks/session-gate.sh — one job class per session. A UserPromptSubmit hook.
#
# Why: every turn re-sends the whole conversation, so a session's cost is turns × context. An
# AUTHORING job (setup, plan, doctor, …) and an EXECUTION job (build-item, pr, review, …) each
# carry their own context; run in one session, everything after the switch pays for both. The
# rule is NOT one skill per session — build-item walking story after story is one job and is
# never blocked — it is that the two classes do not share a session.
#
# Contract:
#   - Reads the UserPromptSubmit payload (prompt, session_id, cwd). Only a prompt that BEGINS
#     with `/devstride:<skill>` or `/ds:<skill>` is a job; anything else exits 0 untouched.
#     Nested invocations (one skill invoking another) never pass through a user prompt, so
#     driven mode needs no exemption.
#   - Records {skill, class, at} per session under <git-common-dir>/devstride/session/
#     <session_id>.json — uncommitted runtime state, the namespace review ledgers and
#     verification receipts already use. Markers older than 7 days are pruned on write.
#   - Blocks (exit 2, one plain-language reason on stderr — that is what the user sees; the
#     prompt is discarded) only when a job of the OTHER class is already recorded in this
#     session. /clear gives a new session_id, which is exactly the cure the message names.
#   - Escape hatches: `--same-session` anywhere in the prompt; `"session": {"jobClassGate":
#     false}` in .claude/ds-config.json; DEVSTRIDE_SESSION_GATE=0 in the environment.
#   - FAILS OPEN. No python3, no git, no session id, an unwritable .git, malformed JSON — every
#     failure exits 0 silently. It may never block real work by accident.
#   - Silent on stdout when it allows; it adds no context to the turn.
set -u
[ "${DEVSTRIDE_SESSION_GATE:-1}" = "0" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0
STDIN_JSON=$(cat 2>/dev/null | head -c 20000)
export SG_STDIN="$STDIN_JSON"
python3 - <<'PY'
import json, os, re, subprocess, sys, time

AUTHORING = {"setup", "plan", "doctor", "ci-audit", "rebalance", "rationalize-gantt", "comprehend-plan"}
EXECUTION = {"build-item", "pr", "review", "release", "push", "create-story", "create-defect",
             "insert-story", "insert-defect"}
TTL = 7 * 24 * 3600

def main():
    try:
        payload = json.loads(os.environ.get("SG_STDIN") or "{}")
    except Exception:
        return 0
    prompt = payload.get("prompt") or ""
    m = re.match(r"\s*/(?:devstride|ds):([a-z][a-z0-9-]*)\b", prompt)
    if not m:
        return 0
    skill = m.group(1)
    cls = "authoring" if skill in AUTHORING else "execution" if skill in EXECUTION else "neutral"
    sid = payload.get("session_id") or ""
    if not sid:
        tp = payload.get("transcript_path") or ""
        sid = os.path.splitext(os.path.basename(tp))[0] if tp else ""
    if not re.match(r"^[A-Za-z0-9._-]{1,128}$", sid):
        return 0
    cwd = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    try:
        top = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5).stdout.strip()
        common = subprocess.run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return 0
    if not top or not common or not os.path.isdir(common):
        return 0
    try:
        with open(os.path.join(top, ".claude", "ds-config.json")) as f:
            session_cfg = (json.load(f).get("session") or {})
        if session_cfg.get("jobClassGate") is False:
            return 0
    except Exception:
        pass  # no config, or unreadable: the gate is on by default
    same = "--same-session" in prompt
    marker_dir = os.path.join(common, "devstride", "session")
    marker = os.path.join(marker_dir, sid + ".json")
    try:
        os.makedirs(marker_dir, mode=0o700, exist_ok=True)
    except Exception:
        return 0
    jobs = []
    try:
        with open(marker) as f:
            jobs = json.load(f).get("jobs") or []
    except Exception:
        jobs = []
    if cls != "neutral" and not same:
        other = "execution" if cls == "authoring" else "authoring"
        prior = [j for j in jobs if j.get("class") == other]
        if prior:
            first = prior[0].get("skill", "?")
            sys.stderr.write(
                "devstride: this session already ran /devstride:%s, an %s job. /devstride:%s is an %s job. "
                "Every turn re-sends the whole conversation, so mixing the two multiplies the cost of everything "
                "after this point. Start it in a new session (/clear, then the same command), or add "
                "--same-session to continue here.\n" % (first, other, skill, cls))
            return 2
    now = int(time.time())
    jobs.append({"skill": skill, "class": cls, "at": now})
    try:
        tmp = marker + ".%d.tmp" % os.getpid()
        with open(tmp, "w") as f:
            json.dump({"sessionId": sid, "jobs": jobs}, f)
        os.replace(tmp, marker)
        for name in os.listdir(marker_dir):
            p = os.path.join(marker_dir, name)
            try:
                if name.endswith(".json") and now - os.stat(p).st_mtime > TTL:
                    os.unlink(p)
            except Exception:
                pass
    except Exception:
        return 0
    return 0

try:
    sys.exit(main())
except SystemExit:
    raise
except Exception:
    sys.exit(0)
PY
