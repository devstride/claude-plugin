#!/bin/bash
# scripts/measure-cost.sh — what a skill costs to load, against committed budgets.
#
# Runs under macOS /bin/bash 3.2: bash does argument parsing only; the logic is
# python3, the toolchain hooks/version-check.sh already assumes.
#
# THE METHOD (fixed here; recorded in scripts/cost-budgets.json as _method):
#   tokens(file) = ceil(utf8_bytes(file) / 3), bytes exactly as `wc -c` prints.
# It is a pure function of the file, needs no dependency, and anyone can
# cross-check it with a one-liner. It over-estimates plain prose and
# under-estimates dense identifier lists; that bias is the same on both sides
# of every before/after table, which is what the tables are for. Changing the
# formula means running --write-budgets in the same commit so every budget is
# re-baselined against the new method and the diff shows both.
#
# What is measured:
#   bodies       every skills/*/SKILL.md, whole file, frontmatter included —
#                it is what loads on invocation. Budgeted.
#   references   every skills/*/references/*.md — informational, never
#                budgeted, listed so moved text can be seen to have MOVED.
#   scripts      hooks/*.sh, scripts/*.sh, skills/*/scripts/* — bytes only,
#                "executed, not loaded".
#   alwaysOn.context   what enters every session's context: the skill listing,
#                the sum over SKILL.md files of "- devstride:<name>: <description>\n"
#                from each frontmatter. Budgeted (alwaysOnContext).
#   alwaysOn.executed  hooks/hooks.json + hooks/version-check.sh +
#                .claude-plugin/plugin.json in bytes — parsed or executed by the
#                harness, never read as context.
#
# Flags:
#   (none)                 human table
#   --check                exit 1 on any OVER / MISSING-BUDGET / STALE-BUDGET /
#                          always-on breach / unparsable budgets; else one ok
#                          line per body
#   --json                 the same data as one JSON document
#   --table --since <ref>  markdown before/after table for CHANGELOG; @ref
#                          columns come from `git show <ref>:<path>`
#   --write-budgets        rewrite the budgets file from the current measurement
#   --budgets <path>       use another budgets file (tests)
set -u
command -v python3 >/dev/null 2>&1 || { echo "measure-cost: python3 is required" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=""; SINCE=""; BUDGETS="$ROOT/scripts/cost-budgets.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--json|--table|--write-budgets) MODE="${1#--}"; shift ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --budgets) BUDGETS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "measure-cost: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$MODE" = "table" ] && [ -z "$SINCE" ]; then echo "measure-cost: --table needs --since <git-ref>" >&2; exit 2; fi
export MC_ROOT="$ROOT" MC_MODE="$MODE" MC_SINCE="$SINCE" MC_BUDGETS="$BUDGETS"
exec python3 - <<'PY'
import glob, json, math, os, re, subprocess, sys, datetime

ROOT, MODE, SINCE, BUDGETS_PATH = (os.environ[k] for k in ("MC_ROOT", "MC_MODE", "MC_SINCE", "MC_BUDGETS"))
METHOD = "tokens = ceil(utf8_bytes / 3); bytes as `wc -c`"

def tokens(nbytes): return math.ceil(nbytes / 3)
def nbytes(path): return os.path.getsize(path)
def rel(p): return os.path.relpath(p, ROOT)

def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    fm = {}
    if m:
        for line in m.group(1).splitlines():
            k, _, v = line.partition(":")
            if _:
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'": v = v[1:-1]
                fm[k.strip()] = v
    return fm

def listing_line(fm):
    return "- devstride:%s: %s\n" % (fm.get("name", "?"), fm.get("description", ""))

def measure(read_body):
    """read_body(name) -> text or None. Returns the always-on context line bytes for a set of bodies."""
    pass

# --- current tree -------------------------------------------------------------------------
bodies = {}
for p in sorted(glob.glob(os.path.join(ROOT, "skills", "*", "SKILL.md"))):
    name = os.path.basename(os.path.dirname(p))
    b = nbytes(p)
    bodies[name] = {"path": rel(p), "bytes": b, "tokens": tokens(b)}
refs = {}
for p in sorted(glob.glob(os.path.join(ROOT, "skills", "*", "references", "*.md"))):
    b = nbytes(p); refs[rel(p)] = {"bytes": b, "tokens": tokens(b)}
scripts = {}
for pat in ("hooks/*.sh", "scripts/*.sh", "skills/*/scripts/*"):
    for p in sorted(glob.glob(os.path.join(ROOT, pat))):
        if os.path.isfile(p): scripts[rel(p)] = {"bytes": nbytes(p)}
ctx_bytes = 0
for name, b in bodies.items():
    with open(os.path.join(ROOT, b["path"]), encoding="utf-8") as f:
        ctx_bytes += len(listing_line(frontmatter(f.read())).encode("utf-8"))
executed_bytes = sum(nbytes(os.path.join(ROOT, p)) for p in ("hooks/hooks.json", "hooks/version-check.sh", ".claude-plugin/plugin.json") if os.path.exists(os.path.join(ROOT, p)))
always = {"context": {"bytes": ctx_bytes, "tokens": tokens(ctx_bytes)}, "executed": {"bytes": executed_bytes}}

# --- budgets --------------------------------------------------------------------------------
def round_up_100(n): return n if n % 100 == 0 else (n // 100 + 1) * 100

if MODE == "write-budgets":
    with open(os.path.join(ROOT, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
        version = json.load(f).get("version", "?")
    out = {
        "_method": METHOD,
        "_generatedBy": "scripts/measure-cost.sh --write-budgets at %s on %s" % (version, datetime.date.today().isoformat()),
        "_rounding": "measured tokens rounded UP to the next multiple of 100",
        "_readme": "A RATCHET. --check fails any skills/<name>/SKILL.md whose tokens exceed its budget. Lower freely. Raise only in the same commit as the text that needs it, and say so in the commit message — or move rationale to a references/ file instead. Changing _method re-baselines every entry in the same commit (--write-budgets).",
        "alwaysOnContext": round_up_100(always["context"]["tokens"]),
        "bodies": {n: round_up_100(b["tokens"]) for n, b in sorted(bodies.items())},
    }
    with open(BUDGETS_PATH, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False); f.write("\n")
    print("wrote %s: %d bodies, alwaysOnContext %d" % (rel(BUDGETS_PATH), len(out["bodies"]), out["alwaysOnContext"]))
    sys.exit(0)

budgets, budget_error = None, None
try:
    with open(BUDGETS_PATH, encoding="utf-8") as f: budgets = json.load(f)
    if not isinstance(budgets.get("bodies"), dict) or not isinstance(budgets.get("alwaysOnContext"), int): raise ValueError("missing bodies/alwaysOnContext")
except Exception as e:  # noqa: BLE001 — a broken budgets file is a failure, not silence
    budget_error = "%s: %s" % (rel(BUDGETS_PATH), e)

problems = []
if budget_error:
    problems.append("BAD-BUDGETS %s" % budget_error)
else:
    for n, b in bodies.items():
        b["budget"] = budgets["bodies"].get(n)
        if b["budget"] is None: problems.append("MISSING-BUDGET %s" % n)
        elif b["tokens"] > b["budget"]: problems.append("OVER %s %s > %s (+%s)" % (b["path"], format(b["tokens"], ","), format(b["budget"], ","), format(b["tokens"] - b["budget"], ",")))
    for n in budgets["bodies"]:
        if n not in bodies: problems.append("STALE-BUDGET %s" % n)
    always["context"]["budget"] = budgets["alwaysOnContext"]
    if always["context"]["tokens"] > always["context"]["budget"]:
        problems.append("OVER alwaysOn.context %s > %s" % (format(always["context"]["tokens"], ","), format(always["context"]["budget"], ",")))
    budgets_method = budgets.get("_method")
    if budgets_method != METHOD: problems.append("METHOD-MISMATCH budgets say %r, script uses %r — re-baseline with --write-budgets" % (budgets_method, METHOD))

# --- output ---------------------------------------------------------------------------------
def fmt(n): return format(n, ",")

if MODE == "check":
    for p in problems: print(p)
    if problems: sys.exit(1)
    for n, b in sorted(bodies.items(), key=lambda kv: -kv[1]["tokens"]):
        print("ok %s %s <= %s" % (b["path"], fmt(b["tokens"]), fmt(b["budget"])))
    print("ok alwaysOn.context %s <= %s" % (fmt(always["context"]["tokens"]), fmt(always["context"]["budget"])))
    sys.exit(0)

if MODE == "json":
    print(json.dumps({"method": METHOD, "bodies": {n: {k: v for k, v in b.items()} for n, b in bodies.items()},
                      "references": refs, "scripts": scripts, "alwaysOn": always,
                      "overBudget": [p for p in problems]}, indent=2, ensure_ascii=False))
    sys.exit(1 if budget_error else 0)

if MODE == "table":
    def git(*args):
        r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True)
        return r.stdout if r.returncode == 0 else None
    head = (git("rev-parse", "--short", "HEAD") or b"?").decode().strip()
    if git("rev-parse", "--verify", SINCE + "^{commit}") is None:
        print("measure-cost: unknown git ref %r" % SINCE, file=sys.stderr); sys.exit(2)
    ref_bodies = {}
    ls = git("ls-tree", "-r", "--name-only", SINCE, "--", "skills") or b""
    ref_ctx = 0
    for path in ls.decode().splitlines():
        parts = path.split("/")
        if len(parts) == 3 and parts[2] == "SKILL.md":
            blob = git("show", "%s:%s" % (SINCE, path)) or b""
            ref_bodies[parts[1]] = {"bytes": len(blob), "tokens": tokens(len(blob))}
            ref_ctx += len(listing_line(frontmatter(blob.decode("utf-8", "replace"))).encode("utf-8"))
    print("<!-- scripts/measure-cost.sh --table --since %s @ %s, method: %s -->" % (SINCE, head, METHOD))
    print("| File | bytes@%s | tokens@%s | bytes now | tokens now | Δ tokens | budget |" % (SINCE, SINCE))
    print("|---|---:|---:|---:|---:|---:|---:|")
    tb = tt = nb = nt = 0
    for n, b in sorted(bodies.items(), key=lambda kv: -kv[1]["tokens"]):
        r = ref_bodies.get(n)
        if r: tb += r["bytes"]; tt += r["tokens"]
        nb += b["bytes"]; nt += b["tokens"]
        delta = ("%+d" % (b["tokens"] - r["tokens"])) if r else "—"
        print("| %s | %s | %s | %s | %s | %s | %s |" % (b["path"], fmt(r["bytes"]) if r else "—", fmt(r["tokens"]) if r else "—", fmt(b["bytes"]), fmt(b["tokens"]), delta, fmt(b["budget"]) if b.get("budget") is not None else "—"))
    print("| alwaysOn.context (skill listing) | %s | %s | %s | %s | %+d | %s |" % (fmt(ref_ctx), fmt(tokens(ref_ctx)), fmt(ctx_bytes), fmt(always["context"]["tokens"]), always["context"]["tokens"] - tokens(ref_ctx), fmt(always["context"].get("budget", 0)) if not budget_error else "—"))
    print("| **total (bodies)** | %s | %s | %s | %s | %+d | |" % (fmt(tb), fmt(tt), fmt(nb), fmt(nt), nt - tt))
    sys.exit(0)

# human table
print("%-40s %9s %8s %8s %9s  %s" % ("body", "bytes", "tokens", "budget", "headroom", "status"))
for n, b in sorted(bodies.items(), key=lambda kv: -kv[1]["tokens"]):
    bud = b.get("budget"); status = "ok" if bud is not None and b["tokens"] <= bud else ("OVER" if bud is not None else "no budget")
    print("%-40s %9s %8s %8s %9s  %s" % (b["path"], fmt(b["bytes"]), fmt(b["tokens"]), fmt(bud) if bud is not None else "—", fmt(bud - b["tokens"]) if bud is not None else "—", status))
print("\n%-40s %9s %8s   (informational — never budgeted)" % ("reference", "bytes", "tokens"))
for p, r in sorted(refs.items(), key=lambda kv: -kv[1]["tokens"]): print("%-40s %9s %8s" % (p, fmt(r["bytes"]), fmt(r["tokens"])))
print("\n%-40s %9s   (executed, not loaded)" % ("script", "bytes"))
for p, s in sorted(scripts.items()): print("%-40s %9s" % (p, fmt(s["bytes"])))
print("\nalwaysOn.context   %s bytes / %s tokens  budget %s — the skill listing every session loads; the session-start hook adds at most two lines of stdout, and only when it speaks" % (fmt(ctx_bytes), fmt(always["context"]["tokens"]), fmt(always["context"].get("budget", 0)) if not budget_error else "—"))
print("alwaysOn.executed  %s bytes — hooks/hooks.json + hooks/version-check.sh + .claude-plugin/plugin.json: parsed or executed by the harness, never read as context" % fmt(executed_bytes))
print("\ntotals: %d bodies %s bytes / %s tokens; %d references %s tokens" % (len(bodies), fmt(sum(b["bytes"] for b in bodies.values())), fmt(sum(b["tokens"] for b in bodies.values())), len(refs), fmt(sum(r["tokens"] for r in refs.values()))))
for p in problems: print(p)
sys.exit(1 if problems else 0)
PY
