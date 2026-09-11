#!/bin/bash
# Deterministic tests for hooks/session-gate.sh — a throwaway repository per case, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$ROOT/hooks/session-gate.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset DEVSTRIDE_SESSION_GATE
mkrepo() { local r="$WORK/$1"; mkdir -p "$r/.claude"; git -C "$r" init -q 2>/dev/null; printf '%s' "${2:-{\}}" > "$r/.claude/ds-config.json"; printf '%s' "$r"; }
# run REPO SESSION PROMPT → stdout+stderr; RC in $?
run() { printf '{"prompt":"%s","session_id":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit"}' "$3" "$2" "$1" | bash "$HOOK" 2>&1; }
marker() { cat "$1/.git/devstride/session/$2.json" 2>/dev/null; }

R="$(mkrepo a)"
# (1) an authoring job then an execution job in one session → blocked, exit 2, plain-language reason
OUT="$(run "$R" s1 '/devstride:setup')"; RC1=$?
OUT2="$(run "$R" s1 '/devstride:build-item I123')"; RC2=$?
if [ $RC1 -eq 0 ] && [ -z "$OUT" ] && [ $RC2 -eq 2 ] && printf '%s' "$OUT2" | grep -q 'already ran /devstride:setup, an authoring job' \
   && printf '%s' "$OUT2" | grep -q -- '--same-session' && printf '%s' "$OUT2" | grep -q '/clear'; then
  ok "(1) setup then build-item → blocked with the reason, the cure and the escape hatch"; else bad "(1) rc=$RC1/$RC2 out=$OUT|$OUT2"; fi
# (2) the blocked job was not recorded; --same-session lets it through and records it
if ! marker "$R" s1 | grep -q build-item; then ok "(2) a blocked job leaves no record"; else bad "(2) $(marker "$R" s1)"; fi
OUT="$(run "$R" s1 '/devstride:build-item I123 --same-session')"; RC=$?
if [ $RC -eq 0 ] && marker "$R" s1 | grep -q '"skill": "build-item"'; then ok "(2b) --same-session → allowed and recorded"; else bad "(2b) rc=$RC $OUT"; fi
# (3) a new session id (what /clear produces) starts clean
OUT="$(run "$R" s2 '/devstride:build-item I123')"; RC=$?
if [ $RC -eq 0 ] && [ -z "$OUT" ]; then ok "(3) new session → allowed"; else bad "(3) rc=$RC $OUT"; fi
# (4) the same class repeats freely: build-item story after story, then pr, review, release
for p in '/devstride:build-item I124' '/devstride:pr' '/devstride:review 7' '/devstride:release' '/ds:push'; do
  OUT="$(run "$R" s2 "$p")"; RC=$?; [ $RC -eq 0 ] || bad "(4) $p rc=$RC $OUT"
done
[ "$(marker "$R" s2 | grep -o '"class": "execution"' | wc -l | tr -d ' ')" = 6 ] && ok "(4) six execution jobs in one session, none blocked" || bad "(4) $(marker "$R" s2)"
# (5) execution first, then authoring → blocked the other way round; the ds: alias counts
OUT="$(run "$R" s2 '/ds:plan I1')"; RC=$?
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q 'already ran /devstride:build-item, an execution job. /devstride:plan is an authoring job'; then ok "(5) execution then plan → blocked; /ds: alias recognised"; else bad "(5) rc=$RC $OUT"; fi
# (6) neutral skills never block and never arm: update, branch-feature, ultracode-build
OUT="$(run "$R" s3 '/devstride:update')"; OUT2="$(run "$R" s3 '/devstride:setup')"; RC=$?
OUT3="$(run "$R" s3 '/devstride:branch-feature x')"; RC3=$?
if [ $RC -eq 0 ] && [ $RC3 -eq 0 ]; then ok "(6) neutral skills (update, branch-feature) neither block nor arm"; else bad "(6) rc=$RC/$RC3 $OUT2 $OUT3"; fi
# (7) ordinary prompts, even ones mentioning a command, are untouched
OUT="$(run "$R" s3 'what does /devstride:build-item do?')"; RC=$?
if [ $RC -eq 0 ] && [ -z "$OUT" ] && ! marker "$R" s3 | grep -q build-item; then ok "(7) a prompt that merely mentions a command is ignored"; else bad "(7) rc=$RC $OUT"; fi
# (8) config opt-out: session.jobClassGate false → never blocks
R2="$(mkrepo b '{"session":{"jobClassGate":false}}')"
run "$R2" s1 '/devstride:setup' >/dev/null; OUT="$(run "$R2" s1 '/devstride:build-item I1')"; RC=$?
if [ $RC -eq 0 ] && [ -z "$OUT" ]; then ok "(8) session.jobClassGate false → gate off"; else bad "(8) rc=$RC $OUT"; fi
# (9) environment opt-out
run "$R" s4 '/devstride:setup' >/dev/null; OUT="$(DEVSTRIDE_SESSION_GATE=0 run "$R" s4 '/devstride:build-item I1')"; RC=$?
if [ $RC -eq 0 ] && [ -z "$OUT" ]; then ok "(9) DEVSTRIDE_SESSION_GATE=0 → gate off"; else bad "(9) rc=$RC $OUT"; fi
# (10) fails open: no session id, not a git repo, malformed JSON, unwritable .git
OUT="$(printf '{"prompt":"/devstride:build-item","cwd":"%s"}' "$R" | bash "$HOOK" 2>&1)"; RC=$?
[ $RC -eq 0 ] && [ -z "$OUT" ] && ok "(10a) no session id → allowed" || bad "(10a) rc=$RC $OUT"
OUT="$(printf '{"prompt":"/devstride:build-item","cwd":"%s","transcript_path":"/tmp/x/abc-123.jsonl"}' "$R" | bash "$HOOK" 2>&1)"; RC=$?
[ $RC -eq 0 ] && marker "$R" abc-123 | grep -q build-item && ok "(10b) session id derived from transcript_path" || bad "(10b) rc=$RC $OUT"
mkdir -p "$WORK/notgit"; OUT="$(run "$WORK/notgit" s1 '/devstride:setup')"; RC=$?
[ $RC -eq 0 ] && [ -z "$OUT" ] && ok "(10c) not a repository → allowed" || bad "(10c) rc=$RC $OUT"
OUT="$(printf 'not json' | bash "$HOOK" 2>&1)"; RC=$?
[ $RC -eq 0 ] && [ -z "$OUT" ] && ok "(10d) malformed payload → allowed" || bad "(10d) rc=$RC $OUT"
R3="$(mkrepo c)"; mkdir -p "$R3/.git/devstride"; chmod 500 "$R3/.git/devstride"
run "$R3" s1 '/devstride:setup' >/dev/null; OUT="$(run "$R3" s1 '/devstride:build-item I1')"; RC=$?
chmod 700 "$R3/.git/devstride"
[ $RC -eq 0 ] && [ -z "$OUT" ] && ok "(10e) unwritable marker directory → allowed (nothing recorded, nothing blocked)" || bad "(10e) rc=$RC $OUT"
# (11) a worktree shares the main repository's session markers (git-common-dir)
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init 2>/dev/null
git -C "$R" worktree add -q "$WORK/a-wt" -b wt 2>/dev/null
OUT="$(run "$WORK/a-wt" s2 '/devstride:doctor')"; RC=$?
[ $RC -eq 2 ] && ok "(11) a worktree sees the main repository's session record" || bad "(11) rc=$RC $OUT"
# (12) stale markers are pruned on write
touch -t 202001010000 "$R/.git/devstride/session/s1.json"; run "$R" s5 '/devstride:push' >/dev/null
[ ! -f "$R/.git/devstride/session/s1.json" ] && [ -f "$R/.git/devstride/session/s5.json" ] && ok "(12) markers older than 7 days pruned" || bad "(12) $(ls "$R/.git/devstride/session")"
exit $FAIL
