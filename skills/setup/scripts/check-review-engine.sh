#!/usr/bin/env bash
# Does the configured local review command actually run read-only?
#
# Contract (skills/setup/references/review-engines.md holds the catalogue and the reasoning):
#   - review.localCommand and review.localAssistCommand are held to contract item 4: the
#     reviewer must not edit the tree it reviews. A catalogued engine has a KNOWN read-only
#     flag, so its absence is a FAIL with the exact fix. An uncatalogued engine can only be
#     held to the contract, so it is UNVERIFIABLE with the contract restated — never a FAIL
#     for being unrecognised.
#   - Any command that switches the sandbox OFF fails whatever the engine, because the flag
#     that disables it is unambiguous wherever it appears.
#   - The engine's own default matters only when the flag is missing: ~/.codex/config.toml's
#     sandbox_mode is reported then, so the operator sees what the command really ran under.
#   - Verified by running the CLI, never by reading its help (codex-cli 0.153.2):
#       codex exec            takes `--sandbox read-only` (or `-s read-only`)
#       codex review          refuses --sandbox and --ephemeral; takes `-c sandbox_mode=read-only`
#       codex exec review     same as codex review, but accepts `-s read-only` BEFORE `review`
#   - Prints one verdict line per command: PASS / FAIL / UNVERIFIABLE, then `Fix:` on a FAIL.
#     Exit 0 when nothing failed, 1 on any FAIL, 2 on usage error. Never reads stdin.
#
# Usage: check-review-engine.sh [--config <path>] [--command '<string>' ...] [--json]
#   default: the repository's .claude/ds-config.json (from the git top level, else the cwd)
set -u
CONFIG=""; JSON=""; CMDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ $# -ge 2 ] || { echo "check-review-engine: --config needs a value" >&2; exit 2; }; CONFIG="$2"; shift 2 ;;
    --command) [ $# -ge 2 ] || { echo "check-review-engine: --command needs a value" >&2; exit 2; }; CMDS+=("$2"); shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "check-review-engine: unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v python3 >/dev/null 2>&1 || { echo "check-review-engine: python3 is required" >&2; exit 2; }
if [ -z "$CONFIG" ] && [ "${#CMDS[@]}" -eq 0 ]; then
  TOP="$(git rev-parse --show-toplevel 2>/dev/null)"; CONFIG="${TOP:-$PWD}/.claude/ds-config.json"
fi
export CRE_CONFIG="$CONFIG" CRE_JSON="$JSON" CRE_HOME="${CODEX_HOME:-$HOME/.codex}"
python3 - "${CMDS[@]+"${CMDS[@]}"}" <<'PY'
import json, os, re, shlex, sys

# The catalogue. `prefix` is matched against the leading tokens; first match wins, so the
# longer `codex exec review` sits above `codex exec`. Every entry names the flag the CLI
# itself accepted when run — see the header — and the fix is the exact edit.
CATALOGUE = [
    {"engine": "codex exec review", "prefix": ["codex", "exec", "review"],
     "accepts": ["config:sandbox_mode=read-only", "sandbox-before-subcommand:read-only"],
     "flag": "-c sandbox_mode=read-only",
     "fix": "add `-c sandbox_mode=read-only` (this subcommand refuses `--sandbox` after `review`)"},
    {"engine": "codex review", "prefix": ["codex", "review"],
     "accepts": ["config:sandbox_mode=read-only"],
     "flag": "-c sandbox_mode=read-only",
     "fix": "add `-c sandbox_mode=read-only` (this subcommand refuses `--sandbox` and `--ephemeral`)"},
    {"engine": "codex exec", "prefix": ["codex", "exec"],
     "accepts": ["sandbox:read-only", "config:sandbox_mode=read-only"],
     "flag": "--sandbox read-only",
     "fix": "add `--sandbox read-only`"},
]
# Anything here switches the sandbox off or widens it; the engine is irrelevant.
DISABLERS = {"--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--yolo"}
WIDE = {"workspace-write", "danger-full-access"}

def tokens(cmd):
    try:
        return shlex.split(cmd)
    except ValueError:
        return cmd.split()

def sandbox_settings(toks, subcommand_at):
    """Every sandbox setting the command carries: (kind, value, position)."""
    out = []
    i = 0
    while i < len(toks):
        t = toks[i]
        if t in ("-c", "--config") and i + 1 < len(toks):
            kv = toks[i + 1].strip('"\'')
            if kv.startswith("sandbox_mode="):
                out.append(("config", kv.split("=", 1)[1].strip('"\''), i)); i += 2; continue
        if t.startswith("-c") and "sandbox_mode=" in t:  # -csandbox_mode=x
            out.append(("config", t.split("=", 1)[1].strip('"\''), i))
        elif t.startswith("--sandbox=") or t.startswith("-s="):
            out.append(("sandbox", t.split("=", 1)[1], i))
        elif t in ("--sandbox", "-s") and i + 1 < len(toks):
            out.append(("sandbox", toks[i + 1], i)); i += 2; continue
        i += 1
    return out

def verdict(key, cmd):
    if cmd is None:
        return {"key": key, "verdict": "PASS", "engine": None,
                "detail": "null — no local engine; the roster degrades to the built-in adversarial pass, a legal configuration"}
    toks = tokens(cmd)
    if not toks:
        return {"key": key, "verdict": "FAIL", "engine": None, "detail": "empty command",
                "fix": "set a catalogued template from review-engines.md, or null"}
    entry = next((e for e in CATALOGUE if toks[:len(e["prefix"])] == e["prefix"]), None)
    engine = entry["engine"] if entry else toks[0]
    disabled = sorted(DISABLERS & set(toks))
    if disabled:
        return {"key": key, "verdict": "FAIL", "engine": engine,
                "detail": "SANDBOX DISABLED by %s — the reviewer can write to the tree it reviews" % ", ".join("`%s`" % d for d in disabled),
                "fix": "remove %s and use the read-only flag (%s)" % (", ".join("`%s`" % d for d in disabled), (entry or {}).get("flag", "the CLI's own read-only flag"))}
    sub_at = len(entry["prefix"]) - 1 if entry else None
    settings = sandbox_settings(toks, sub_at)
    wide = [s for s in settings if s[1] in WIDE]
    if wide:
        return {"key": key, "verdict": "FAIL", "engine": engine,
                "detail": "SANDBOX WIDENED to `%s` — the reviewer can write to the tree it reviews" % wide[0][1],
                "fix": "replace it with %s" % ((entry or {}).get("flag", "the CLI's read-only setting"))}
    if entry is None:
        ro = [s for s in settings if s[1] == "read-only"]
        return {"key": key, "verdict": "UNVERIFIABLE", "engine": engine,
                "detail": ("uncatalogued engine `%s` — held to the contract only: it must run read-only. " % engine)
                          + ("A read-only setting is present (`%s`); confirm the CLI honours it by running it." % toks[ro[0][2]] if ro
                             else "No recognisable read-only flag; confirm one from the CLI itself, not its help, and add it to the command.")}
    ok = False
    for s in settings:
        if s[0] == "config" and s[1] == "read-only" and "config:sandbox_mode=read-only" in entry["accepts"]:
            ok = True
        if s[0] == "sandbox" and s[1] == "read-only":
            if "sandbox:read-only" in entry["accepts"]:
                ok = True
            if "sandbox-before-subcommand:read-only" in entry["accepts"] and s[2] < sub_at:
                ok = True
    if ok:
        return {"key": key, "verdict": "PASS", "engine": engine, "detail": "read-only flag present (%s)" % entry["flag"]}
    misplaced = [s for s in settings if s[0] == "sandbox" and s[1] == "read-only"]
    detail = "MISSING READ-ONLY FLAG — `%s` needs `%s`" % (engine, entry["flag"])
    if misplaced:
        detail += "; the `--sandbox read-only` present is refused by this subcommand at that position, so it never took effect"
    default = codex_default()
    if default:
        detail += "; without it the command ran under ~/.codex/config.toml sandbox_mode = \"%s\"" % default
    return {"key": key, "verdict": "FAIL", "engine": engine, "detail": detail, "fix": entry["fix"]}

def codex_default():
    try:
        with open(os.path.join(os.environ.get("CRE_HOME", ""), "config.toml")) as f:
            m = re.search(r'^\s*sandbox_mode\s*=\s*"([^"]+)"', f.read(), re.M)
            return m.group(1) if m else None
    except Exception:
        return None

cmds = sys.argv[1:]
results = []
if cmds:
    for i, c in enumerate(cmds):
        results.append(verdict("command[%d]" % i, c))
else:
    path = os.environ["CRE_CONFIG"]
    try:
        with open(path) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        print("UNVERIFIABLE: no config at %s — run /devstride:setup first" % path); sys.exit(0)
    except Exception as e:
        print("FAIL: %s is not valid JSON (%s)" % (path, e)); sys.exit(1)
    review = cfg.get("review") if isinstance(cfg.get("review"), dict) else {}
    for key in ("localCommand", "localAssistCommand"):
        if key in review:
            results.append(verdict("review.%s" % key, review[key]))
        elif key == "localCommand":
            results.append(verdict("review.localCommand", None))
if os.environ.get("CRE_JSON"):
    print(json.dumps({"results": results, "failed": any(r["verdict"] == "FAIL" for r in results)}))
else:
    for r in results:
        print("%s %s: %s" % (r["verdict"], r["key"], r["detail"]))
        if r.get("fix"):
            print("  Fix: %s" % r["fix"])
sys.exit(1 if any(r["verdict"] == "FAIL" for r in results) else 0)
PY
