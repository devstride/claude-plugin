#!/bin/bash
# The release.clearance.scope text stays whole: clearance.md documents EVERY scope and the scripts
# each cites, merge-and-deploy's queue (cut behind the release ahead, prepared on top of it, rebuilt
# when production moves, handed back at deploy-confirmed) is described where the skill reads it, every heartbeat phase its cut-to-deploy section names is one the default section lists,
# and the release skill points at the section, names the `post-deploy only` argument, and every
# script the section cites exists. Pure text checks; no git, no gh.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cat > "$W/check.py" <<'PY'
import os, re, sys
root = sys.argv[1]
c = open(os.path.join(root, "skills/release/references/clearance.md")).read()
skill = open(os.path.join(root, "skills/release/SKILL.md")).read()
problems = []
default = c.split("## Where the release skill calls it", 1)[1].split("\n## ", 1)[0]
scope = c.split("## Scope `cut-to-deploy`", 1)[1].split("\n## ", 1)[0] if "## Scope `cut-to-deploy`" in c else ""
default, scope = re.sub(r"\s+", " ", default), re.sub(r"\s+", " ", scope)
if not scope: problems.append("clearance.md has no '## Scope `cut-to-deploy`' section")
if '"release"' not in c or '"cut-to-deploy"' not in c: problems.append("clearance.md does not name both scope values")
listed = set(re.findall(r"`([a-z-]+)(?: --[a-z]+ <[a-z]+>)?` (?:before|after|on|as)", default))
named = set(re.findall(r"`heartbeat ([a-z-]+)", scope)) | set(re.findall(r"`([a-z-]+) --branch", scope))
for phase in sorted(named):
    if phase not in listed: problems.append("phase %r in the cut-to-deploy section is not in the default list %s" % (phase, sorted(listed)))
if "train" not in listed: problems.append("the default list lost `train` (parsed: %s)" % sorted(listed))
for script in ("post-deploy-status.sh", "previous-release-gate.sh"):
    if script not in scope: problems.append("the section does not name %s" % script)
    if not os.path.isfile(os.path.join(root, "skills/release/scripts", script)): problems.append("%s does not exist" % script)
for needle in ("post-deploy only", "cut-to-deploy", "merge-and-deploy", "step aside",
               "no heartbeat before that step 4 claim", "Never proceed uncleared under scopes"):
    if needle not in skill: problems.append("release SKILL.md does not mention %r" % needle)
# merge-and-deploy: its section exists, every phase it heartbeats is a default phase, and every
# script it cites exists
mad = c.split("## Scope `merge-and-deploy`", 1)[1].split("\n## ", 1)[0] if "## Scope `merge-and-deploy`" in c else ""
mad = re.sub(r"\s+", " ", mad)
if not mad: problems.append("clearance.md has no '## Scope `merge-and-deploy`' section")
if '"merge-and-deploy"' not in c: problems.append("clearance.md does not name the merge-and-deploy scope value")
for phase in sorted(set(re.findall(r"`heartbeat ([a-z-]+)", mad))):
    if phase not in listed: problems.append("phase %r in the merge-and-deploy section is not in the default list %s" % (phase, sorted(listed)))
for script in ("release_checks.py", "tower-queue.py", "previous-release-gate.sh"):
    if script not in mad: problems.append("the merge-and-deploy section does not name %s" % script)
    if not os.path.isfile(os.path.join(root, "skills/release/scripts", script)): problems.append("%s does not exist" % script)
for needle in ("release --step-aside", "rerunAtMerge", "release-holder", "no heartbeat before step 4's claim"):
    if needle not in mad: problems.append("the merge-and-deploy section does not mention %r" % needle)
# the queue (the tower held only for the merge and the deploy): the cut waits at the queue, the
# release is prepared on top of the one ahead (production brought in, then the checks), it is
# rebuilt when production moves, the gate reads pending from the merge on, and the tower is handed
# back at deploy-confirmed with the sync owed after the post-deploy check
for needle in ("first cut, first merged", "release_checks.py contains", "Rebuilt when what is ahead changes",
               "pending", "--owed post-deploy-check --owed sync", "owed --done sync", "train claim is handed on"):
    if needle not in mad: problems.append("the merge-and-deploy section does not mention %r" % needle)
for stale in ("Pre-claim checks", "The queue, before every claim"):
    if stale in mad: problems.append("the merge-and-deploy section still says %r (the checks no longer run before every claim)" % stale)
branch = re.sub(r"\s+", " ", open(os.path.join(root, "skills/release/references/release-branch.md")).read())
if "owed item `sync`" not in branch: problems.append("release-branch.md §5 does not name the owed item `sync` under merge-and-deploy")
auto = re.sub(r"\s+", " ", open(os.path.join(root, "skills/release/references/auto-start.md")).read())
if "once step 1 has opened the release pull request" not in auto: problems.append("auto-start.md does not say where merge-and-deploy hands the train claim on")
print("\n".join(problems) or "OK")
PY
OUT="$(python3 "$W/check.py" "$ROOT")"
[ "$OUT" = OK ] && ok "clearance.md documents every scope; phases, scripts and the release skill agree" || bad "$OUT"
exit $FAIL
