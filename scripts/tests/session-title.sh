#!/bin/bash
# Deterministic tests for hooks/session-title.py — the repository's session.titleCommand names an
# unnamed session through Claude Code's own title. Each case runs against a private cache and
# throwaway repositories; the stand-in "repository command" records its environment and stdin, and
# prints whatever title (and second line) the case asks for.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$ROOT/hooks/session-title.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export XDG_CACHE_HOME="$WORK/cache"
unset SESSION_TITLE SESSION_TITLE_OWNED CLAUDE_CODE_SESSION_ID
RECORDS="$XDG_CACHE_HOME/devstride-plugin/session-title"
SAID="$WORK/said"; mkdir -p "$SAID"

# The repository's command: records what it was given, then prints $SAID/title and $SAID/second.
TC="$WORK/bin/tc.py"; mkdir -p "$WORK/bin"
cat > "$TC" <<'PY'
import json, os, sys
said = os.environ["TC_SAID"]
data = sys.stdin.buffer.read()
with open(os.path.join(said, "env.json"), "w") as f:
    json.dump({"sid": os.environ.get("CLAUDE_CODE_SESSION_ID"), "title": os.environ.get("SESSION_TITLE"),
               "owned": os.environ.get("SESSION_TITLE_OWNED"), "cwd": os.getcwd(), "stdin": len(data),
               "head": data[:16].decode("utf-8", "replace")}, f)
sys.stderr.write("noise on stderr\n")
def read(name):
    try:
        return open(os.path.join(said, name)).read()
    except OSError:
        return ""
sys.stdout.write(read("title"))
if read("second"):
    sys.stdout.write("\n" + read("second"))
PY
export TC_SAID="$SAID"
say() { printf '%s' "$1" > "$SAID/title"; printf '%s' "${2:-}" > "$SAID/second"; rm -f "$SAID/env.json"; }
said() { python3 -c 'import json,sys; v = json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$SAID/env.json" "$1" 2>/dev/null; }

mkrepo() { # mkrepo NAME CONFIG-JSON
  local d="$WORK/$1"; mkdir -p "$d/.claude" "$d/sub/dir"; git -C "$d" init -q -b main 2>/dev/null
  printf '%s' "$2" > "$d/.claude/ds-config.json"
  git -C "$d" add -A; git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init; printf '%s' "$d"
}
R="$(mkrepo repo "{\"session\":{\"titleCommand\":\"python3 '$TC'\"}}")"
PLAIN="$(mkrepo plain '{"session":{"nameCommand":"echo x"}}')"
BLANK="$(mkrepo blank '{"session":{"titleCommand":"  "}}')"

# fire EVENT SID CWD [EXTRA-JSON] — run the hook; its stdout lands in $OUT, its exit code in $RC
fire() {
  OUT="$(printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s"%s}' "$1" "$2" "$3" "${4:-}" \
    | python3 "$HOOK" hook)"; RC=$?
}
title_of() { printf '%s' "$OUT" | python3 -c 'import json,sys
d = json.loads(sys.stdin.read() or "null")
h = d["hookSpecificOutput"]
print(h["hookEventName"], h["sessionTitle"], sep="|")' 2>/dev/null; }

# (1) no titleCommand (absent or blank) → nothing runs, nothing printed, nothing written
say "never"
fire UserPromptSubmit s1 "$PLAIN" ',"prompt":"hi"'; A="$OUT$RC"
fire SessionStart s1 "$BLANK" ',"source":"startup"'; B="$OUT$RC"
fire UserPromptSubmit s1 "$WORK" ',"prompt":"hi"'; C="$OUT$RC"
if [ "$A" = 0 ] && [ "$B" = 0 ] && [ "$C" = 0 ] && [ ! -e "$SAID/env.json" ] && [ ! -e "$XDG_CACHE_HOME" ]; then
  ok "(1) no titleCommand, a blank one, or no repository → nothing runs, prints or is written"
else bad "(1) a=$A b=$B c=$C ran=$([ -e "$SAID/env.json" ] && echo yes) cache=$(ls -R "$XDG_CACHE_HOME" 2>/dev/null)"; fi

# (2) an unnamed session → sessionTitle for UserPromptSubmit and SessionStart startup/resume/fork,
#     with the event's own name; clear and compact run nothing
say "Widget work"
fire UserPromptSubmit s2 "$R" ',"prompt":"build it"'; U="$(title_of)"
fire SessionStart s2b "$R" ',"source":"startup"'; S1="$(title_of)"
fire SessionStart s2c "$R" ',"source":"resume"'; S2="$(title_of)"
fire SessionStart s2d "$R" ',"source":"fork"'; S3="$(title_of)"
say "Widget work"; fire SessionStart s2e "$R" ',"source":"clear"'; X1="$OUT$RC"
fire SessionStart s2e "$R" ',"source":"compact"'; X2="$OUT$RC"
if [ "$U" = "UserPromptSubmit|Widget work" ] && [ "$S1" = "SessionStart|Widget work" ] && [ "$S2" = "SessionStart|Widget work" ] \
   && [ "$S3" = "SessionStart|Widget work" ] && [ "$X1" = 0 ] && [ "$X2" = 0 ] && [ ! -e "$SAID/env.json" ]; then
  ok "(2) unnamed → sessionTitle for UserPromptSubmit and SessionStart startup/resume/fork; clear/compact run nothing"
else bad "(2) u=$U s1=$S1 s2=$S2 s3=$S3 x1=$X1 x2=$X2"; fi

# (3) the environment: session id, the custom title, ownership; run from the config root even from a
#     subdirectory; the prompt on stdin; SessionStart sends an empty stdin; stderr and extra output dropped
say "Env check"
fire UserPromptSubmit s3 "$R/sub/dir" ',"prompt":"hello prompt"'; E1="$(said sid)|$(said title)|$(said owned)|$(said head)|$(said stdin)"
CWD3="$(said cwd)"
fire SessionStart s3 "$R/sub/dir" ',"source":"resume","session_title":"Env check"'; E2="$(said title)|$(said owned)|$(said stdin)|$OUT"
if [ "$E1" = "s3|||hello prompt|12" ] && [ "$CWD3" = "$(cd "$R" && pwd -P)" -o "$CWD3" = "$R" ] && [ "$E2" = "Env check|1|0|" ]; then
  ok "(3) CLAUDE_CODE_SESSION_ID, SESSION_TITLE, SESSION_TITLE_OWNED=1 for its own title; config root; prompt on stdin; SessionStart stdin empty"
else bad "(3) e1=$E1 cwd=$CWD3 e2=$E2"; fi

# (4) a custom title the hook did not set is never touched, and is not OWNED; a title equal to the
#     hook's own is replaced; the same title prints nothing
say "Auto name"
fire UserPromptSubmit s4 "$R" ',"prompt":"x","session_title":"Person name"'; P1="$OUT|$(said owned)"
fire UserPromptSubmit s4 "$R" ',"prompt":"x"'; P2="$(title_of)"
say "Auto name two"
fire UserPromptSubmit s4 "$R" ',"prompt":"x","session_title":"Auto name"'; P3="$(title_of)|$(said owned)"
fire UserPromptSubmit s4 "$R" ',"prompt":"x","session_title":"Auto name two"'; P4="$OUT$RC"
fire UserPromptSubmit s4 "$R" ',"prompt":"x","session_title":"Person renamed"'; P5="$OUT|$(said owned)"
if [ "$P1" = "|" ] && [ "$P2" = "UserPromptSubmit|Auto name" ] && [ "$P3" = "UserPromptSubmit|Auto name two|1" ] \
   && [ "$P4" = 0 ] && [ "$P5" = "|" ]; then
  ok "(4) a person's title is never replaced; the hook's own title is; the same title prints nothing"
else bad "(4) p1=$P1 p2=$P2 p3=$P3 p4=$P4 p5=$P5"; fi

# (5) `replace` applies over a person's title, and the title it set is then a person's (not OWNED)
say "Asked for" replace
fire UserPromptSubmit s5 "$R" ',"prompt":"x","session_title":"Person name"'; Q1="$(title_of)"
say "Auto again"
fire UserPromptSubmit s5 "$R" ',"prompt":"x","session_title":"Asked for"'; Q2="$OUT|$(said owned)"
say "Asked again" "  replace  "
fire UserPromptSubmit s5 "$R" ',"prompt":"x","session_title":"Asked for"'; Q3="$(title_of)"
say "Not asked" "replaced"
fire UserPromptSubmit s5 "$R" ',"prompt":"x","session_title":"Asked again"'; Q4="$OUT"
if [ "$Q1" = "UserPromptSubmit|Asked for" ] && [ "$Q2" = "|" ] && [ "$Q3" = "UserPromptSubmit|Asked again" ] && [ -z "$Q4" ]; then
  ok "(5) line 2 'replace' applies over a person's title and is never OWNED; any other second line is not replace"
else bad "(5) q1=$Q1 q2=$Q2 q3=$Q3 q4=$Q4"; fi

# (6) cleaning: control characters and | become spaces, whitespace collapses, 64 characters at most;
#     a title that cleans to nothing, or empty output, prints nothing
say "$(printf 'a|b\tc   d')"; fire UserPromptSubmit s6 "$R" ',"prompt":"x"'; K1="$(title_of)"
LONG="$(python3 -c 'print("w" * 200, end="")')"; say "$LONG"; fire UserPromptSubmit s6b "$R" ',"prompt":"x"'; K2="$(title_of)"
say " | "; fire UserPromptSubmit s6c "$R" ',"prompt":"x"'; K3="$OUT$RC"
say ""; fire UserPromptSubmit s6d "$R" ',"prompt":"x"'; K4="$OUT$RC"
if [ "$K1" = "UserPromptSubmit|a b c d" ] && [ "$K2" = "UserPromptSubmit|$(python3 -c 'print("w" * 64, end="")')" ] \
   && [ "$K3" = 0 ] && [ "$K4" = 0 ]; then
  ok "(6) the title is cleaned (|, tab, runs of spaces) and cut to 64; an empty or blank title prints nothing"
else bad "(6) k1=$K1 k2=$K2 k3=$K3 k4=$K4"; fi

# (7) the prompt on stdin is capped at 8 KB, never inside a character
BIG="$(python3 -c 'print("é" * 9000, end="")')"
say "Big"; fire UserPromptSubmit s7 "$R" ",\"prompt\":\"$BIG\""; N="$(said stdin)"
if [ "$N" = 8192 ] && [ "$(title_of)" = "UserPromptSubmit|Big" ]; then
  ok "(7) an 18 KB prompt reaches the command as 8192 bytes of whole characters"
else bad "(7) stdin=$N out=$OUT"; fi

# (8) a failing command, a hanging one, or a command that ignores stdin and exits non-zero → no
#     output, exit 0, within the 3 s limit; the hung command's process group is killed
F1="$(mkrepo fail '{"session":{"titleCommand":"echo Some title; exit 3"}}')"
fire UserPromptSubmit s8 "$F1" ',"prompt":"x"'; H1="$OUT$RC"
F2="$(mkrepo hang "{\"session\":{\"titleCommand\":\"echo Late; echo \$\$ > '$WORK/hang.pid'; sleep 30\"}}")"
T0=$(date +%s); fire UserPromptSubmit s8 "$F2" ',"prompt":"x"'; T1=$(date +%s); H2="$OUT$RC"
HP="$(cat "$WORK/hang.pid" 2>/dev/null)"; sleep 0.3
if [ "$H1" = 0 ] && [ "$H2" = 0 ] && [ $((T1 - T0)) -le 5 ] && [ -n "$HP" ] && ! kill -0 "$HP" 2>/dev/null; then
  ok "(8) failing or hanging command → nothing printed, exit 0, within $((T1 - T0)) s; the hung command is killed"
else bad "(8) h1=$H1 h2=$H2 took=$((T1 - T0)) pid=$HP alive=$(kill -0 "$HP" 2>/dev/null && echo yes)"; kill "$HP" 2>/dev/null; fi

# (9) bad payloads (not JSON, no or unsafe session id, another event) → nothing, exit 0
say "Nope"
printf 'not json' | python3 "$HOOK" hook >"$WORK/o9" 2>&1; Z1="$?$(cat "$WORK/o9")"
fire UserPromptSubmit "../escape" "$R" ',"prompt":"x"'; Z2="$OUT$RC"
fire Stop s9 "$R"; Z3="$OUT$RC"
python3 "$HOOK" other </dev/null >"$WORK/o9" 2>&1; Z4="$?$(cat "$WORK/o9")"
if [ "$Z1" = 0 ] && [ "$Z2" = 0 ] && [ "$Z3" = 0 ] && [ "$Z4" = 0 ] && [ ! -e "$SAID/env.json" ]; then
  ok "(9) not JSON, an unsafe session id, another event, another mode → nothing runs, nothing printed"
else bad "(9) z1=$Z1 z2=$Z2 z3=$Z3 z4=$Z4"; fi

# (10) a record that cannot be written means no title is printed (it could never be told apart later)
chmod 500 "$RECORDS"
say "Unrecorded"; fire UserPromptSubmit s10 "$R" ',"prompt":"x"'; W1="$OUT$RC"
chmod 700 "$RECORDS"
if [ "$W1" = 0 ]; then ok "(10) an unwritable record → no title printed, exit 0"; else bad "(10) w1=$W1"; fi

# (11) records: owner-only under XDG_CACHE_HOME only; another session's record older than 7 days is
#      pruned at a new session's start, a fresh one and the session's own are kept; the repository and
#      the plugin directory stay clean (no compiled files)
MODE="$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)), oct(stat.S_IMODE(os.stat(sys.argv[2]).st_mode)))' "$RECORDS" "$RECORDS/s2.json")"
printf '{"title":"old","own":true}' > "$RECORDS/gone.json"; touch -t 202001010000 "$RECORDS/gone.json"
printf '{"title":"old","own":true}' > "$RECORDS/s11.json"; touch -t 202001010000 "$RECORDS/s11.json"
say "Fresh"; fire SessionStart s11 "$R" ',"source":"startup"'
if [ "$MODE" = "0o700 0o600" ] && [ ! -e "$RECORDS/gone.json" ] && [ -e "$RECORDS/s11.json" ] && [ -e "$RECORDS/s4.json" ] \
   && [ -z "$(git -C "$R" status --porcelain --untracked-files=all)" ] && [ ! -e "$ROOT/hooks/__pycache__" ] \
   && [ "$(title_of)" = "SessionStart|Fresh" ]; then
  ok "(11) records owner-only under XDG_CACHE_HOME; a stale record of another session pruned at start; repository and plugin clean"
else bad "(11) mode=$MODE gone=$([ -e "$RECORDS/gone.json" ] && echo kept) repo=$(git -C "$R" status --porcelain) out=$OUT"; fi

# (12) the hook is wired for UserPromptSubmit and for SessionStart startup|resume|fork, bounded and
#      guarded so a missing python3 fails open
WIRED="$(python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
found = []
for event, groups in hooks.items():
    for group in groups:
        for h in group["hooks"]:
            if "hooks/session-title.py" in h["command"]:
                ok = h["command"].startswith("command -v python3 >/dev/null 2>&1 && ") and h["command"].endswith("; exit 0") \
                    and h.get("timeout") == 5
                found.append("%s:%s:%s" % (event, group.get("matcher", "*"), ok))
print(" ".join(sorted(found)))
PY
)"
[ "$WIRED" = "SessionStart:startup|resume|fork:True UserPromptSubmit:*:True" ] \
  && ok "(12) hooks.json runs it on UserPromptSubmit and SessionStart startup|resume|fork, guarded and bounded" \
  || bad "(12) wired: $WIRED"

exit $FAIL
