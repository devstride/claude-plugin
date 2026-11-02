#!/bin/bash
# Tests for this repository's own delivery-loop files: .claude/ds-config.json, .claude/settings.json,
# CLAUDE.md and .gitignore. They are maintainer files (never shipped), but the loop reads them on
# every build here, so a broken key fails silently at the worst moment.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

OUT="$(python3 - "$ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
problems = []
def need(cond, msg):
    if not cond:
        problems.append(msg)
try:
    c = json.load(open(os.path.join(root, ".claude/ds-config.json"), encoding="utf-8"))
except (OSError, ValueError) as e:
    print("ds-config.json unreadable: %s" % e); sys.exit()
need(c.get("profile") == "standard", "profile is not standard")
need(c.get("baseBranch") == "main" and c.get("hotfixBaseBranch") == "main", "baseBranch/hotfixBaseBranch are not main")
need(c.get("integrationBranch") is None, "integrationBranch is set")
need(c.get("epicIntegrationBranches", {}).get("enabled") is False,
     "epic integration branches are on: the loop finds landed stories by item numbers in git, which this repository forbids")
need(c.get("protectedBranches") == ["main"], "protectedBranches is not [main]")
need("stage" not in c, "a stage block is present: this repository deploys nothing")
need(c.get("branchNaming", {}).get("dateFormat") == "YY-MM-DD", "branchNaming.dateFormat is not YY-MM-DD")
need(c.get("release", {}).get("productionBranch") == "main", "release.productionBranch is not main")
# This repository is public: no pattern, template or tag format may carry an item number.
text = json.dumps(c)
need(not re.search(r"<I#+>|<itemNumber>|\bI[0-9]{4,6}\b", text), "an item-number placeholder or literal is configured")
need(not c.get("itemTagFormat"), "itemTagFormat is set: commits here carry no item tags")
mp = c.get("mergePath", {})
need(mp.get("guardedBases") == ["main"], "mergePath.guardedBases is not [main]")
need(all(p in mp.get("allowedHeadPatterns", []) for p in mp.get("epicHeadPatterns", [])) and mp.get("epicHeadPatterns"),
     "every epic head pattern must also be an allowed head pattern")
need(mp.get("overrideLabel") == "merge-path-override", "mergePath.overrideLabel is not merge-path-override")
v = c.get("verify", {})
for cmd in list(v.get("typecheck", [])) + [v.get("test", ""), v.get("lint", "")]:
    m = re.search(r"\bbash (\S+\.sh)", cmd or "")
    need(bool(m) and os.path.isfile(os.path.join(root, m.group(1))), "verify command names a missing script: %r" % cmd)
need(os.path.isdir(os.path.join(root, v.get("testDir", "-"))), "verify.testDir does not exist")
r = c.get("review", {})
need(r.get("openPullRequestsAsDraft") and r.get("readyForReviewReleasesCi") and r.get("ciHeldUntilReviewSettled"),
     "the three draft-hold booleans are not all true")
need(r.get("automatedReviewers") == [], "a cloud reviewer is configured")
lenses = {l.get("name"): l for l in r.get("mandatoryLenses", [])}
need("rule-loss-and-config-keys" in lenses and "skills/**" in lenses["rule-loss-and-config-keys"].get("paths", []),
     "the rule-loss lens over skills/** is missing")
need(c.get("conventionsDoc") == "AGENTS.md", "conventionsDoc is not AGENTS.md")
try:
    s = json.load(open(os.path.join(root, ".claude/settings.json"), encoding="utf-8"))
    src = s.get("extraKnownMarketplaces", {}).get("devstride", {}).get("source", {})
    need(src.get("repo") == "devstride/claude-plugin", "settings.json does not register devstride/claude-plugin")
    need(s.get("enabledPlugins", {}).get("devstride@devstride") is True, "settings.json does not enable devstride@devstride")
except (OSError, ValueError) as e:
    problems.append("settings.json unreadable: %s" % e)
need(open(os.path.join(root, "CLAUDE.md"), encoding="utf-8").read().strip() == "@AGENTS.md", "CLAUDE.md is not @AGENTS.md")
ignored = [l.strip() for l in open(os.path.join(root, ".gitignore"), encoding="utf-8")]
need(not [l for l in ignored if l in (".claude", ".claude/", "/.claude", "/.claude/")], ".gitignore ignores .claude/")
print("\n".join(problems))
PY
)"
if [ -z "$OUT" ]; then ok "(1) ds-config, settings, CLAUDE.md and .gitignore hold this repository's loop setup"
else bad "(1) $OUT"; fi

exit $FAIL
