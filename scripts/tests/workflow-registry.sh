#!/bin/bash
# scripts/tests/workflow-registry.sh — the append-only version registry (workflows/registry.json,
# scripts/workflow-registry.py): the shipped registry passes its own check and its history page is
# current; every refusal of `check` has a failing case (an edited or a deleted row against the
# base, a definition whose fingerprint has no row at its version, a version that goes backwards or
# skips, a changed fingerprint at a released version unless that row is dormant and nothing can run
# the definition, a new slip row, a note that is not fit to publish, a stale page); `record`
# appends and never edits a released row; `stamp` names the release in every unreleased row with
# its date and a note from the CHANGELOG, and `verify-stamp` proves it; and the page generator
# matches its golden fixture (scripts/tests/fixtures/registry-history/).
#
#   bash scripts/tests/workflow-registry.sh             run the cases
#   bash scripts/tests/workflow-registry.sh --golden    rewrite the golden page (after a deliberate
#                                                       change to the page's layout, never by hand)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
GOLDEN="$ROOT/scripts/tests/fixtures/registry-history"

cat > "$WORK/cases.py" <<'PY'
import json, os, shutil, subprocess, sys
ROOT, WORK, GOLDEN, MODE = sys.argv[1:5]
SCRIPT = os.path.join(ROOT, "scripts/workflow-registry.py")
FAILED = []
_spec = __import__("importlib.util").util.spec_from_file_location("workflow_registry", SCRIPT)
wr = __import__("importlib.util").util.module_from_spec(_spec); _spec.loader.exec_module(wr)


def check(label, good, detail=""):
    print(("  ok   " if good else "  FAIL ") + label + ("" if good else " -> %s" % (detail,)))
    if not good:
        FAILED.append(label)


def run(root, *args):
    done = subprocess.run([sys.executable, os.path.join(root, "scripts/workflow-registry.py")] + list(args) + ["--root", root],
                          capture_output=True, text=True)
    return done.returncode, done.stdout + done.stderr


def git(root, *args):
    return subprocess.run(["git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com",
                           "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + list(args),
                          capture_output=True, text=True, check=True).stdout


def plugin_copy(name, with_git=True):
    """A copy of the parts of the plugin the registry reads, committed on `main` as the base, with
    a `story` branch checked out on top."""
    root = os.path.join(WORK, name)
    for sub in ("workflows", "schemas", "scripts", ".claude-plugin", "skills"):
        os.makedirs(os.path.join(root, sub), exist_ok=True)
    for f in os.listdir(os.path.join(ROOT, "workflows")):
        shutil.copy(os.path.join(ROOT, "workflows", f), os.path.join(root, "workflows"))
    for f in ("step-contracts.json", "workflow-registry.schema.json"):
        shutil.copy(os.path.join(ROOT, "schemas", f), os.path.join(root, "schemas"))
    for f in ("workflow-registry.py", "check-public-hygiene.sh", "public-hygiene.allow"):
        shutil.copy(os.path.join(ROOT, "scripts", f), os.path.join(root, "scripts"))
    shutil.copy(os.path.join(ROOT, ".claude-plugin/plugin.json"), os.path.join(root, ".claude-plugin"))
    shutil.copy(os.path.join(ROOT, "CHANGELOG.md"), root)
    for skill in os.listdir(os.path.join(ROOT, "skills")):
        os.symlink(os.path.join(ROOT, "skills", skill), os.path.join(root, "skills", skill))
    if with_git:
        git(root, "init", "-q", "-b", "main")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "base")
        git(root, "checkout", "-qb", "story")
    return root


def load(root):
    return json.load(open(os.path.join(root, "workflows/registry.json"), encoding="utf-8"))


def save(root, registry):
    with open(os.path.join(root, "workflows/registry.json"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps(registry, indent=2, ensure_ascii=False) + "\n")


def regenerate(root):
    rc, out = run(root, "history", "--write")
    assert rc == 0, out


def edit_definition(root, wid, fn):
    path = os.path.join(root, "workflows/%s.json" % wid)
    d = json.load(open(path, encoding="utf-8")); fn(d)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(d, handle, indent=2)


def entry_of(root, wid):
    return wr.Plugin(root).workflow_entry(json.load(open(os.path.join(root, "workflows/%s.json" % wid), encoding="utf-8")))


def faulted(out, text):
    return any(line.startswith("REGISTRY FAULT: ") and text in line for line in out.splitlines())


# (1) the shipped registry: it passes, every definition and contract has its row, the page is current.
rc, out = run(ROOT, "check", "--base", "none")
check("(1) the shipped registry passes its own check", rc == 0 and out.strip().endswith(")") and "REGISTRY: ok" in out, out)
rc, out = run(ROOT, "history", "--check")
check("(1b) the shipped history page is current", rc == 0 and out.strip() == "HISTORY: current", out)
shipped = load(ROOT)
check("(1c) the shipped registry holds no unreleased row", all(r["pluginVersion"] != "unreleased"
      for group in ("workflows", "contracts") for rows in shipped[group].values() for r in rows))

# (2) the base comparison.
root = plugin_copy("edited")
reg = load(root); reg["workflows"]["build"][0]["note"] = "Rewritten later."; save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "main")
check("(2a) an edited released row is refused", rc == 1 and faulted(out, "workflow build 1: a released row was edited"), out)

root = plugin_copy("deleted")
reg = load(root); del reg["contracts"]["risk-check"][1]; save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "main")
check("(2b) a deleted released row is refused", rc == 1 and faulted(out, "contract risk-check 1: a released row was deleted"), out)

root = plugin_copy("refingerprinted")
reg = load(root); reg["workflows"]["hotfix"][0]["sha256"] = "0" * 64; save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "main")
check("(2c) a released row whose fingerprint was edited is refused, and so is the definition left without its row",
      rc == 1 and faulted(out, "a released row was deleted or its fingerprint edited") and faulted(out, "hotfix: changed since version 1"), out)

root = plugin_copy("auto-base")
git(root, "update-ref", "refs/remotes/origin/develop", "main")
reg = load(root); reg["workflows"]["plan"][0]["releasedAt"] = "2026-11-23"; save(root, reg); regenerate(root)
rc, out = run(root, "check")
check("(2d) with no --base the merge base with origin/develop is the base", rc == 1 and "base: merge base with origin/develop" in out
      and faulted(out, "workflow plan 1: a released row was edited"), out)

# (3) the definitions against the registry.
root = plugin_copy("unrecorded-change", with_git=False)
edit_definition(root, "hotfix", lambda d: d["phases"][0]["steps"][0].__setitem__("summary", "Changed without a bump."))
regenerate(root)
rc, out = run(root, "check", "--base", "none")
check("(3a) a definition whose fingerprint has no row at its version is refused", rc == 1 and faulted(out, "hotfix: changed since version 1"), out)
rc, out = run(root, "record")
check("(3b) ... and record refuses to record it", rc == 1 and "changed but its version did not" in out, out)

root = plugin_copy("unrecorded-version", with_git=False)
edit_definition(root, "plan", lambda d: d.__setitem__("version", 2))
regenerate(root)
rc, out = run(root, "check", "--base", "none")
check("(3c) a bumped definition with no row is refused", rc == 1 and faulted(out, "plan: version 2 is not its newest recorded version 1"), out)

# (4) the order of rows.
root = plugin_copy("backwards", with_git=False)
reg = load(root); row = dict(reg["workflows"]["build"][0]); row["sha256"] = "1" * 64
reg["workflows"]["build"].append(row); save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "none")
check("(4a) a version that goes backwards is refused", rc == 1 and faulted(out, "build v1: the version goes backwards"), out)

root = plugin_copy("skips", with_git=False)
reg = load(root); row = dict(reg["workflows"]["hotfix"][0]); row.update({"version": 3, "sha256": "2" * 64})
reg["workflows"]["hotfix"].append(row); save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "none")
check("(4b) a version that skips is refused", rc == 1 and faulted(out, "hotfix v3: the version skips"), out)

root = plugin_copy("contract-skips", with_git=False)
reg = load(root); row = dict(reg["contracts"]["claim"][0]); row.update({"major": 3, "sha256": "3" * 64})
reg["contracts"]["claim"].append(row); save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "none")
check("(4c) a contract major that skips is refused", rc == 1 and faulted(out, "claim@3: the major skips"), out)

# (5) a changed fingerprint at a released version: refused, unless the row is dormant and nothing can run it.
root = plugin_copy("runnable-changed")
edit_definition(root, "hotfix", lambda d: d["phases"][0]["steps"][0].__setitem__("summary", "Changed at version 1."))
reg = load(root); reg["workflows"]["hotfix"].append(wr.workflow_row(entry_of(root, "hotfix"), False)); save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "main")
check("(5a) a changed fingerprint at a released version is refused", rc == 1 and faulted(out, "hotfix v1: its content changed at a version already recorded"), out)

root = plugin_copy("dormant-rerecord")
edit_definition(root, "release-post-deploy", lambda d: d["phases"][-1]["steps"][-1].__setitem__("summary", "A changed health-check step."))
rc, rout = run(root, "record"); regenerate(root)
rc2, out = run(root, "check", "--base", "main")
rows = load(root)["workflows"]["release-post-deploy"]
check("(5b) a definition nothing can run, re-recorded at its version as dormant, passes (the 2026-11-22 exception)",
      rc == 0 and rc2 == 0 and len(rows) == 2 and rows[1]["version"] == 1 and rows[1].get("dormant") is True, (rout, out))

root = plugin_copy("dormant-but-runnable")
reg = load(root)
for r in reg["workflows"]["hotfix"]:
    r["dormant"] = True
save(root, reg); regenerate(root); git(root, "commit", "-qam", "base with a dormant hotfix row"); git(root, "branch", "-f", "main")
edit_definition(root, "hotfix", lambda d: d["phases"][0]["steps"][0].__setitem__("summary", "Changed at version 1."))
rc, rout = run(root, "record")
check("(5c) record will not re-record a definition this plugin can run, even over a dormant row", rc == 1 and "changed but its version did not" in rout, rout)
reg = load(root); reg["workflows"]["hotfix"].append(wr.workflow_row(entry_of(root, "hotfix"), True)); save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "main")
check("(5d) ... and check refuses a hand-made dormant row for a definition this plugin can run",
      rc == 1 and faulted(out, "workflow hotfix 1: re-recorded as dormant, but this plugin can run it"), out)

# (6) slips are history only.
root = plugin_copy("new-slip")
edit_definition(root, "hotfix", lambda d: d["phases"][0]["steps"][0].__setitem__("summary", "Slipped."))
reg = load(root); row = wr.workflow_row(entry_of(root, "hotfix"), False)
row.update({"pluginVersion": "4.8.0", "releasedAt": "2026-11-22", "note": "Content changed without a version bump.", "slip": True})
reg["workflows"]["hotfix"].append(row); save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "main")
check("(6a) a new row marked slip is refused", rc == 1 and faulted(out, "workflow hotfix 1: a new row cannot be marked slip"), out)
reg = load(root); reg["workflows"]["hotfix"][-1].update({"pluginVersion": "unreleased", "releasedAt": None}); save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "none")
check("(6b) an unreleased row marked slip is refused", rc == 1 and faulted(out, "only a historical row can be a slip"), out)

# (7) notes and released rows.
root = plugin_copy("notes", with_git=False)
reg = load(root)
reg["workflows"]["build"][1]["note"] = "Fixed in I" + "12345."
reg["contracts"]["claim"][0]["note"] = "Two\nlines."
reg["workflows"]["plan"][0]["note"] = ""
save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "none")
check("(7a) a note carrying an item number is refused by the public hygiene check", rc == 1 and faulted(out, "a note is not fit to publish: item-number"), out)
check("(7b) a note on two lines is refused", faulted(out, "contract claim 1: a note is one plain line"), out)
check("(7c) a released row with no note is refused", faulted(out, "plan v1: a released row needs its note"), out)

root = plugin_copy("schema", with_git=False)
reg = load(root); reg["workflows"]["build"][0]["extra"] = 1; save(root, reg)
rc, out = run(root, "check", "--base", "none")
check("(7d) a row the schema does not allow is refused", rc == 1 and faulted(out, "unexpected key extra"), out)

root = plugin_copy("stale", with_git=False)
with open(os.path.join(root, "workflows/HISTORY.md"), "a", encoding="utf-8") as handle:
    handle.write("A line added by hand.\n")
rc, out = run(root, "check", "--base", "none")
check("(7e) a stale history page is refused", rc == 1 and faulted(out, "workflows/HISTORY.md is stale"), out)

# (8) record appends, then stamp names the release.
root = plugin_copy("stamp")
edit_definition(root, "hotfix", lambda d: (d.__setitem__("version", 2), d.__setitem__("minPluginVersion", "unreleased")))
with open(os.path.join(root, "schemas/step-contracts.json"), encoding="utf-8") as handle:
    catalog = json.load(handle)
catalog["contracts"]["hotfix-fix@1"]["summary"] = catalog["contracts"]["hotfix-fix@1"]["summary"] + " Now with more."
with open(os.path.join(root, "schemas/step-contracts.json"), "w", encoding="utf-8") as handle:
    json.dump(catalog, handle, indent=2)
before = load(root)
rc, rout = run(root, "record"); regenerate(root)
after = load(root)
check("(8a) record appends a row for the bumped definition and a revision for the changed contract, and nothing else",
      rc == 0 and len(after["workflows"]["hotfix"]) == 2 and after["workflows"]["hotfix"][0] == before["workflows"]["hotfix"][0]
      and after["workflows"]["hotfix"][1]["pluginVersion"] == "unreleased" and len(after["contracts"]["hotfix-fix"]) == 2
      and sum(len(r) for r in after["workflows"].values()) == sum(len(r) for r in before["workflows"].values()) + 1, rout)
rc, out = run(root, "check", "--base", "main")
check("(8b) the appended rows pass the check before the release names them", rc == 0, out)
rc, out = run(root, "verify-stamp", "9.9.9")
check("(8c) verify-stamp refuses a row still unreleased", rc == 1 and "workflow hotfix 2 is still unreleased" in out, out)
changelog = open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8").read().replace(
    "## [Unreleased]\n", "## [Unreleased]\n\n## [9.9.9] — 2026-11-22\n\n### Added\n\n"
    "- **Something else entirely.** Not about the workflow.\n"
    "- **The Hotfix workflow gains a step (I" "12345).** It runs\n  after the fix.\n\n### Cost\n\n| table |\n", 1)
open(os.path.join(root, "CHANGELOG.md"), "w", encoding="utf-8").write(changelog)
manifest = json.load(open(os.path.join(root, ".claude-plugin/plugin.json"), encoding="utf-8")); manifest["version"] = "9.9.9"
json.dump(manifest, open(os.path.join(root, ".claude-plugin/plugin.json"), "w", encoding="utf-8"), indent=2)
rc, out = run(root, "stamp", "9.9.9", "--date", "2026-11-22")
stamped = load(root)
row = stamped["workflows"]["hotfix"][1]
check("(8d) stamp names the version and the date in every unreleased row", rc == 0 and "REGISTRY STAMP: 2 row(s) set to 9.9.9" in out
      and row["pluginVersion"] == "9.9.9" and row["releasedAt"] == "2026-11-22" and row["minPluginVersion"] == "9.9.9"
      and stamped["contracts"]["hotfix-fix"][1]["pluginVersion"] == "9.9.9", (out, row))
check("(8e) ... the empty note is filled from the version's CHANGELOG entry that names the workflow, without its item number",
      row["note"] == "The Hotfix workflow gains a step.", row["note"])
check("(8f) ... a contract's empty note falls back to the section's first entry",
      stamped["contracts"]["hotfix-fix"][1]["note"] == "Something else entirely.", stamped["contracts"]["hotfix-fix"][1]["note"])
rc, out = run(root, "verify-stamp", "9.9.9")
check("(8g) verify-stamp then passes and the page was rewritten", rc == 0 and "REGISTRY STAMP: verified 9.9.9" in out, out)
rc, out = run(root, "check", "--base", "main")
check("(8h) the stamped registry still passes the check against the base", rc == 0, out)
again = open(os.path.join(root, "workflows/registry.json"), encoding="utf-8").read()
rc, out = run(root, "stamp", "9.9.9", "--date", "2026-11-23")
check("(8i) a second stamp changes nothing", rc == 0 and "nothing to stamp" in out
      and open(os.path.join(root, "workflows/registry.json"), encoding="utf-8").read() == again, out)
git(root, "commit", "-qam", "stamped"); git(root, "branch", "-f", "main")
reg = load(root); reg["workflows"]["hotfix"][1]["note"] = "Changed after the release."; save(root, reg); regenerate(root)
rc, out = run(root, "check", "--base", "main")
check("(8j) once released, a stamped row is protected like any other", rc == 1 and faulted(out, "workflow hotfix 2: a released row was edited"), out)

# (9) the page generator against its golden fixture.
root = os.path.join(WORK, "golden")
for sub in ("workflows", ".claude-plugin", "skills"):
    os.makedirs(os.path.join(root, sub))
shutil.copy(os.path.join(GOLDEN, "registry.json"), os.path.join(root, "workflows"))
shutil.copy(os.path.join(ROOT, ".claude-plugin/plugin.json"), os.path.join(root, ".claude-plugin"))
os.makedirs(os.path.join(root, "scripts")); shutil.copy(SCRIPT, os.path.join(root, "scripts"))
os.symlink(os.path.join(ROOT, "skills/build-item"), os.path.join(root, "skills/build-item"))
rc, page = run(root, "history")
if MODE == "--golden":
    open(os.path.join(GOLDEN, "expected.md"), "w", encoding="utf-8").write(page)
    print("  wrote %s" % os.path.join("scripts/tests/fixtures/registry-history", "expected.md"))
expected = open(os.path.join(GOLDEN, "expected.md"), encoding="utf-8").read()
check("(9) the history page matches its golden fixture", rc == 0 and page == expected,
      "".join(__import__("difflib").unified_diff(expected.splitlines(True), page.splitlines(True), "expected", "generated"))[:2000])

sys.exit(1 if FAILED else 0)
PY

if python3 "$WORK/cases.py" "$ROOT" "$WORK" "$GOLDEN" "${1:-check}"; then
  echo "workflow-registry: PASS"
else
  echo "workflow-registry: FAIL"; exit 1
fi
