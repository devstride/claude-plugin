#!/bin/bash
# Tests for skills/review/scripts/reviewed-status.py — the settled-review proof a release reads — on a
# scratch git repository with a `gh` stub on PATH that keeps posted statuses in a temp dir. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; TOOL="$ROOT/skills/review/scripts/reviewed-status.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/st"
# gh stub: statuses live in $WORK/st/<sha>.json (newest first); a POST prepends one by $GH_LOGIN
# (default "owner") stamped after every status already there. Permission: admin for "owner", write
# for "partner", HTTP 404 for anyone else. `gh pr view <n>` answers {state OPEN, headRefOid $PR_HEAD,
# baseRefName $PR_BASE (default train)}. GH_FAIL=1 fails every call.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env python3
import datetime, json, os, sys
a = sys.argv[1:]
if os.environ.get("GH_FAIL"):
    sys.stderr.write("gh: HTTP 502\n"); sys.exit(1)
d = os.environ["ST"]
def later(old):
    t = max([datetime.datetime.strptime(s["created_at"], "%Y-%m-%dT%H:%M:%SZ") for s in old] or [datetime.datetime(2026, 12, 1, 9)])
    return (t + datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
if a[:2] == ["pr", "view"]:
    print(json.dumps({"state": os.environ.get("PR_STATE", "OPEN"), "headRefOid": os.environ.get("PR_HEAD", ""),
                      "baseRefName": os.environ.get("PR_BASE", "train")})); sys.exit(0)
if a[:3] == ["api", "-X", "POST"]:
    sha = a[3].rsplit("/", 1)[1]
    f = dict(x.split("=", 1) for x in a[4:] if "=" in x)
    path = os.path.join(d, sha + ".json")
    old = json.load(open(path)) if os.path.exists(path) else []
    new = {"id": 1000 + len(old), "context": f["context"], "state": f["state"], "description": f.get("description"),
           "created_at": later(old), "creator": {"login": os.environ.get("GH_LOGIN", "owner"), "type": "User"}}
    json.dump([new] + old, open(path, "w")); print(json.dumps(new)); sys.exit(0)
if a[0] == "api" and "/statuses?" in a[1]:
    sha = a[1].split("/commits/")[1].split("/")[0]
    path = os.path.join(d, sha + ".json")
    print(open(path).read() if os.path.exists(path) else "[]"); sys.exit(0)
if a[0] == "api" and "/collaborators/" in a[1]:
    login = a[1].split("/collaborators/")[1].split("/")[0]
    if login not in ("owner", "partner"):
        sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
    print(json.dumps({"permission": "admin" if login == "owner" else "write"})); sys.exit(0)
sys.stderr.write("gh stub: unexpected %r\n" % a); sys.exit(1)
STUB
chmod +x "$WORK/bin/gh"; export ST="$WORK/st" PATH="$WORK/bin:$PATH" REVIEWED_STATUS_WAIT=0
export GIT_AUTHOR_NAME=jane GIT_AUTHOR_EMAIL=jane@example.com GIT_COMMITTER_NAME=jane GIT_COMMITTER_EMAIL=jane@example.com
R="$WORK/repo"; mkdir "$R"; cd "$R" || exit 2
git init -q -b main; echo a > a.txt; git add -A; git commit -qm base; BASE="$(git rev-parse HEAD)"
git checkout -q -b feat; echo b > b.txt; git add -A; git commit -qm feat; REVIEWED="$(git rev-parse HEAD)"
git checkout -q main; echo c > c.txt; git add -A; git commit -qm other; git checkout -q -b rebased
git cherry-pick "$REVIEWED" >/dev/null; REBASED="$(git rev-parse HEAD)"    # same change on a moved base: another tree
git checkout -q -b same "$REVIEWED"; git commit -q --amend -m "feat (reworded)"; SAME="$(git rev-parse HEAD)"   # same tree

# inject SHA ID LOGIN STATE [DESCRIPTION] [TYPE]: a status newer than every one already on SHA
inject() {
  python3 - "$ST/$1.json" "$2" "$3" "$4" "${5:-Settled review of #7 into train}" "${6:-User}" "${CTX:-devstride/reviewed}" <<'PY'
import datetime, json, os, sys
f, i, login, state, desc, kind, ctx = sys.argv[1:]
s = json.load(open(f)) if os.path.exists(f) else []
t = max([datetime.datetime.strptime(x["created_at"], "%Y-%m-%dT%H:%M:%SZ") for x in s] or [datetime.datetime(2026, 12, 1, 9)]) + datetime.timedelta(hours=1)
s.insert(0, {"id": int(i), "context": ctx, "state": state, "description": desc,
             "created_at": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "creator": {"login": login, "type": kind}})
json.dump(s, open(f, "w"))
PY
}
t() { OUT="$(python3 "$TOOL" "$@" 2>&1)"; RC=$?; }
V() { t verify "$1" --pr 7 --base train; }

V "$REVIEWED"
[ "$RC" = 2 ] && [[ "$OUT" == UNREVIEWED*"no devstride/reviewed status from a repository admin"*"for #7 into train" ]] && ok "(1) no status: UNREVIEWED" || bad "(1) $RC $OUT"
PR_HEAD="$REVIEWED" t post "$REVIEWED" --pr 7 --base train
[ "$RC" = 0 ] && [ "$OUT" = "POSTED $REVIEWED devstride/reviewed: Settled review of #7 into train" ] && ok "(2) post on the reviewed head names the pull request and its base" || bad "(2) $RC $OUT"
V "$REVIEWED"
[ "$RC" = 0 ] && [ "$OUT" = "REVIEWED $REVIEWED by owner" ] && ok "(3) an admin's success status verifies for that pull request and base" || bad "(3) $RC $OUT"
t verify "$REVIEWED" --pr 9 --base train
[ "$RC" = 2 ] && ok "(3b) ... and never for another pull request" || bad "(3b) $RC $OUT"
t verify "$REVIEWED" --pr 7 --base jane/26-10-01/epic-x
[ "$RC" = 2 ] && ok "(3c) ... or another base (a story review never proves the epic's merge)" || bad "(3c) $RC $OUT"
GH_LOGIN=partner PR_HEAD="$BASE" t post "$BASE" --pr 7 --base train
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED posted, but it does not count as proof"* ]] && ok "(4) a post by someone without admin permission says it does not count" || bad "(4) $RC $OUT"
V "$BASE"; [ "$RC" = 2 ] && ok "(4b) ... and does not verify" || bad "(4b) $RC $OUT"
inject "$REVIEWED" 5000 partner failure
V "$REVIEWED"; [ "$RC" = 0 ] && ok "(5) a later non-admin status never overrides an admin's proof" || bad "(5) $RC $OUT"
inject "$REVIEWED" 5001 "github-actions[bot]" failure "x" Bot
inject "$REVIEWED" 5002 ghost-user failure
V "$REVIEWED"; [ "$RC" = 0 ] && ok "(5b) a bot's status and an unknown account's (permission 404) are ignored, never fatal" || bad "(5b) $RC $OUT"
CTX=Devstride/Reviewed inject "$REVIEWED" 6000 owner failure "withdrawn"
V "$REVIEWED"
[ "$RC" = 2 ] && [[ "$OUT" == *"an admin withdrew the devstride/reviewed proof"*"failure"* ]] && ok "(6) an admin withdraws the proof with a newer failure (context matched case-insensitively)" || bad "(6) $RC $OUT"
PR_HEAD="$REVIEWED" t post "$REVIEWED" --pr 7 --base train
PR_HEAD="$SAME" t post "$SAME" --pr 7 --base train --from "$REVIEWED"
[ "$RC" = 0 ] && [[ "$OUT" == *"Settled review of #7 into train, carried from ${REVIEWED:0:12} (same tree)" ]] && ok "(7) a tree-identical rebase carries the proof" || bad "(7) $RC $OUT"
V "$SAME"; [ "$RC" = 0 ] && ok "(7b) ... and it verifies" || bad "(7b) $RC $OUT"
PR_HEAD="$REBASED" t post "$REBASED" --pr 7 --base train --from "$REVIEWED"
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED"*"not a tree-identical rebase"* ]] && ok "(8) a rebase onto a moved base (another tree) carries nothing" || bad "(8) $RC $OUT"
PR_HEAD="$SAME" PR_BASE=develop t post "$SAME" --pr 7 --base develop --from "$REVIEWED"
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED"*"no proof to carry over"* ]] && ok "(9) carrying a proof earned against another base posts nothing" || bad "(9) $RC $OUT"
PR_HEAD="$SAME" PR_BASE=train t post "$SAME" --pr 7 --base jane/26-10-01/epic-x
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED #7 is based on train now, not jane/26-10-01/epic-x"* ]] && ok "(9a) a pull request retargeted after its review gets no proof" || bad "(9a) $RC $OUT"
PR_HEAD="$BASE" t post "$SAME" --pr 7 --base train
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED"*"is not the head of #7"* ]] && ok "(9b) never posted on a commit that is not the pull request's head" || bad "(9b) $RC $OUT"
PR_HEAD="$SAME" PR_STATE=MERGED t post "$SAME" --pr 7 --base train
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED"*"not an open pull request"* ]] && ok "(9c) never posted on a merged pull request (no proof after the fact)" || bad "(9c) $RC $OUT"
t post "$SAME" --pr 7; [ "$RC" = 2 ] && [[ "$OUT" == usage:* ]] && ok "(9d) post without --base is a usage error" || bad "(9d) $RC $OUT"
t post abc123 --pr 7 --base train; [ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED"*"not a full commit SHA"* ]] && ok "(10) a short SHA is refused" || bad "(10) $RC $OUT"
GH_FAIL=1 V "$REVIEWED"; [ "$RC" = 1 ] && [[ "$OUT" == ERROR* ]] && ok "(11) GitHub unreadable: ERROR, never REVIEWED" || bad "(11) $RC $OUT"
GH_FAIL=1 t post "$REVIEWED" --pr 7 --base train; [ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED"* ]] && ok "(12) a failed post says NOT POSTED" || bad "(12) $RC $OUT"
PR_HEAD="$SAME" t post "$SAME" --pr 7 --base origin/train
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED --base 'origin/train': pass the bare branch name"* ]] && ok "(10b) a remote ref as --base is refused with the expected form" || bad "(10b) $RC $OUT"
PR_HEAD="$SAME" t post "$SAME" --pr 7 --base "$BASE"
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED --base"*"never a remote ref or a SHA" ]] && ok "(10c) a SHA as --base is refused" || bad "(10c) $RC $OUT"
t verify; [ "$RC" = 2 ] && [[ "$OUT" == usage:* ]] && ok "(13) usage" || bad "(13) $RC $OUT"
t verify "$REVIEWED" --pr 7; [ "$RC" = 2 ] && [[ "$OUT" == usage:* ]] && ok "(13b) --pr without --base is a usage error" || bad "(13b) $RC $OUT"

# The landing proof (post-landing / verify-landing): a LOCAL-FULL review of a train one-off, no pull request.
GATE="$ROOT/skills/build-item/scripts/review-gate.py"
mkdir -p .claude; echo '{"releaseTrain": {"branch": "train", "reviewEveryLanding": true}}' > .claude/ds-config.json
git update-ref refs/remotes/origin/train "$BASE"; git checkout -q feat
L() { t verify-landing "$1" --onto train; }
L "$REVIEWED"
[ "$RC" = 2 ] && [[ "$OUT" == UNREVIEWED*"no devstride/landing-reviewed status from a repository admin"*"for landing onto train" ]] && ok "(14) no landing proof: UNREVIEWED" || bad "(14) $RC $OUT"
t post-landing "$REVIEWED" --onto train
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED this checkout holds no settled LOCAL-FULL receipt for ${REVIEWED:0:12} onto origin/train"* ]] && ok "(15) post-landing refuses a head this checkout holds no settled receipt for" || bad "(15) $RC $OUT"
L "$REVIEWED"; [ "$RC" = 2 ] && ok "(15b) ... and posted nothing" || bad "(15b) $RC $OUT"
echo '{"base": "origin/train", "cycles": 1, "engines": [{"engine": "claude", "result": "no-findings"}], "findings": []}' \
  | python3 "$GATE" record >/dev/null 2>&1 || bad "(16) setup: review-gate.py record failed"
t post-landing "$REVIEWED" --onto train
[ "$RC" = 0 ] && [ "$OUT" = "POSTED $REVIEWED devstride/landing-reviewed: Settled LOCAL-FULL review for landing onto train" ] && ok "(16) with a settled receipt here, post-landing posts the proof on the reviewed head" || bad "(16) $RC $OUT"
L "$REVIEWED"; [ "$RC" = 0 ] && [ "$OUT" = "REVIEWED $REVIEWED by owner" ] && ok "(16b) ... and it verifies for landing onto that train" || bad "(16b) $RC $OUT"
t verify-landing "$REVIEWED" --onto other; [ "$RC" = 2 ] && ok "(16c) ... never for another train" || bad "(16c) $RC $OUT"
L "$SAME"; [ "$RC" = 2 ] && ok "(16d) a pull-request proof (devstride/reviewed) is never a landing proof" || bad "(16d) $RC $OUT"
GH_LOGIN=partner t post-landing "$REVIEWED" --onto train
L "$REVIEWED"; [ "$RC" = 0 ] && ok "(17) a non-admin's later landing status changes nothing" || bad "(17) $RC $OUT"
GH_LOGIN=partner git checkout -q same; GH_LOGIN=partner t post-landing "$SAME" --onto train
[ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED"* ]] && ok "(17b) a head with no receipt of its own gets no proof, even one with the same tree" || bad "(17b) $RC $OUT"
CTX=devstride/landing-reviewed inject "$REVIEWED" 7000 owner failure "withdrawn"
L "$REVIEWED"; [ "$RC" = 2 ] && [[ "$OUT" == *"an admin withdrew the devstride/landing-reviewed proof"* ]] && ok "(18) an admin withdraws a landing proof with a newer failure" || bad "(18) $RC $OUT"
t post-landing "$REVIEWED" --onto origin/train; [ "$RC" = 2 ] && [[ "$OUT" == "NOT POSTED --onto 'origin/train'"* ]] && ok "(19) a remote ref as --onto is refused" || bad "(19) $RC $OUT"
t post-landing "$REVIEWED"; [ "$RC" = 2 ] && [[ "$OUT" == usage:* ]] && ok "(19b) post-landing without --onto is a usage error" || bad "(19b) $RC $OUT"
GH_FAIL=1 L "$REVIEWED"; [ "$RC" = 1 ] && [[ "$OUT" == ERROR* ]] && ok "(19c) GitHub unreadable: ERROR, never REVIEWED" || bad "(19c) $RC $OUT"
exit $FAIL
