#!/bin/bash
# Tests for skills/build-item/scripts/claim_record.py — the record every story claim carries: one
# spelling per machine (the recorded fleet name, else the cleaned-up hostname), the session's own
# name, and a payload whose four keys are always present. Release clearance and the presence hook
# use the same machine name. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/claim_record.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

OUT="$(python3 - "$ROOT" "$T" <<'PY'
import json, os, subprocess, sys
root, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "skills", "build-item", "scripts"))
import claim_record as cr

def check(name, got, want):
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else " — got %r, want %r" % (got, want)))

# (1) the machine name: the recorded fleet name wins; else the hostname; one spelling either way
check("(1a) fleet name wins over the hostname", cr.machine_name({"DEVSTRIDE_MACHINE_NAME": "m5-alice"}, "Mac.local"), "m5-alice")
check("(1b) fleet name typed in capitals is lower-cased", cr.machine_name({"DEVSTRIDE_MACHINE_NAME": "M3-Alice"}, "x"), "m3-alice")
check("(1c) hostname without .local", cr.machine_name({}, "Alices-MacBook-Pro.local"), "alices-macbook-pro")
check("(1d) other characters become one hyphen, trimmed", cr.machine_name({}, "  Phil!s  Mac.localdomain "), "phil-s-mac-localdomain")
check("(1e) an empty fleet name falls back to the hostname", cr.machine_name({"DEVSTRIDE_MACHINE_NAME": ""}, "box"), "box")
check("(1f) nothing usable gives an empty name", cr.machine_name({}, "..."), "")

# (2) the session name: the Claude Code session record (the CLAUDE_PID one first, then any naming this id), else DEVSTRIDE_SESSION
home = os.path.join(tmp, "home"); sessions = os.path.join(home, ".claude", "sessions"); os.makedirs(sessions)
def put(pid, record):
    with open(os.path.join(sessions, "%s.json" % pid), "w") as handle:
        handle.write(record if isinstance(record, str) else json.dumps(record))
put(900, {"sessionId": "s-1", "name": "from pid"})
put(100, {"sessionId": "s-1", "name": "other record"})
put(300, {"sessionId": "s-2", "name": "  two\x07\nlines | pipe  "})
put(400, "not json")
check("(2a) the CLAUDE_PID record first", cr.session_name({"CLAUDE_CODE_SESSION_ID": "s-1", "CLAUDE_PID": "900"}, home), "from pid")
check("(2b) else any record naming the session id", cr.session_name({"CLAUDE_CODE_SESSION_ID": "s-2", "CLAUDE_PID": "999"}, home), "two lines pipe")
check("(2c) a record for another session is never used", cr.session_name({"CLAUDE_CODE_SESSION_ID": "s-1", "CLAUDE_PID": "300"}, home), "other record")
check("(2d) no record → DEVSTRIDE_SESSION", cr.session_name({"CLAUDE_CODE_SESSION_ID": "s-9", "DEVSTRIDE_SESSION": "wt-a"}, home), "wt-a")
check("(2e) nothing known → none", cr.session_name({}, home), None)
alt = os.path.join(tmp, "alt-config"); os.makedirs(os.path.join(alt, "sessions"))
with open(os.path.join(alt, "sessions", "5.json"), "w") as handle:
    json.dump({"sessionId": "s-7", "name": "from config dir"}, handle)
check("(2g) CLAUDE_CONFIG_DIR holds the session records when set", cr.session_name({"CLAUDE_CODE_SESSION_ID": "s-7", "CLAUDE_PID": "5", "CLAUDE_CONFIG_DIR": alt}, home), "from config dir")
check("(2f) a long name is capped at 200", len(cr.session_name({"DEVSTRIDE_SESSION": "x" * 500}, home)), 200)

# (3) the record: four payload keys always, in and out of a checkout
repo = os.path.join(tmp, "wt7")
subprocess.run(["git", "init", "-q", "-b", "feature/x", repo], check=True)
env = {"DEVSTRIDE_MACHINE_NAME": "m1-bob", "CLAUDE_CODE_SESSION_ID": "s-1", "CLAUDE_PID": "900"}
got = cr.record(repo, env, home)
check("(3a) the record in a checkout", got, {"machine": "m1-bob", "sessionName": "from pid", "payload": {
    "sessionId": "s-1", "checkout": "wt7", "branch": "feature/x", "pluginVersion": cr.plugin_version()}})
check("(3b) the plugin version is from this copy", cr.plugin_version() == json.load(open(os.path.join(root, ".claude-plugin", "plugin.json")))["version"], True)
outside = os.path.join(tmp, "plain"); os.makedirs(outside)
got = cr.record(outside, {"DEVSTRIDE_MACHINE_NAME": "m1-bob", "CODEX_THREAD_ID": "t-1"}, home)
check("(3c) outside a checkout: same keys, null values, no sessionName", (sorted(got), sorted(got["payload"]), got["payload"]["checkout"], got["payload"]["branch"], got["payload"]["sessionId"]),
      (["machine", "payload"], ["branch", "checkout", "pluginVersion", "sessionId"], None, None, "t-1"))
PY
)"; PRC=$?
echo "$OUT" | sed 's/^ok   /  ok   /; s/^FAIL /  FAIL /'
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$PRC" -eq 0 ] || bad "(0) the Python cases crashed (exit $PRC)"

# (4) the command line: the record as JSON, `machine` alone, a usable error when there is no name
J="$(cd "$T" && DEVSTRIDE_MACHINE_NAME=M5-Carol CLAUDE_CODE_SESSION_ID= DEVSTRIDE_SESSION=s python3 "$HELPER")"
if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["machine"]=="m5-carol" and d["sessionName"]=="s" and sorted(d["payload"])==["branch","checkout","pluginVersion","sessionId"]' "$J"; then
  ok "(4a) prints the record as one JSON object"; else bad "(4a) got $J"; fi
[ "$(DEVSTRIDE_MACHINE_NAME=M5-Carol python3 "$HELPER" machine)" = "m5-carol" ] && ok "(4b) machine prints the name alone" || bad "(4b) machine"
E="$(DEVSTRIDE_MACHINE_NAME='***' python3 "$HELPER" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 1 ] && echo "$E" | grep -q "set DEVSTRIDE_MACHINE_NAME" && ok "(4c) no usable name → exit 1 naming the fix" || bad "(4c) rc=$RC $E"
python3 "$HELPER" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "(4d) a bad argument → usage, exit 2" || bad "(4d) usage"

# (5) release clearance and presence name the machine the same way, never from the raw hostname
if grep -q "socket.gethostname" "$ROOT/skills/release/scripts/clearance_core.py" "$ROOT/hooks/presence.py"; then
  bad "(5) clearance or presence still reads the raw hostname"
else ok "(5) clearance and presence use the shared machine name"; fi

exit $FAIL
