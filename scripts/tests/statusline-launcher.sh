#!/bin/bash
# Tests for skills/setup/references/statusline-launcher.sh — the small file a repository commits as
# .claude/statusline.sh, which runs the status line of the plugin version the session has loaded.
# Everything runs against throwaway plugin roots, a private cache and a private plugin registry.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; L="$ROOT/skills/setup/references/statusline-launcher.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

WORK="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$WORK"' EXIT
export XDG_CACHE_HOME="$WORK/xdg" CLAUDE_CONFIG_DIR="$WORK/claude" TMPDIR="$WORK/tmp"
mkdir -p "$CLAUDE_CONFIG_DIR/plugins" "$TMPDIR"
unset CLAUDE_PLUGIN_ROOT
SESSIONS="$XDG_CACHE_HOME/devstride-plugin/sessions"
REGISTRY="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"

# python3 through a counting shim: the launcher must not start it on an ordinary draw.
REAL_PY="$(command -v python3)"; mkdir -p "$WORK/bin"; PYLOG="$WORK/python.log"
printf '#!/bin/bash\necho run >> "%s"\nexec "%s" "$@"\n' "$PYLOG" "$REAL_PY" > "$WORK/bin/python3"; chmod +x "$WORK/bin/python3"
pyruns() { [ -f "$PYLOG" ] && wc -l < "$PYLOG" | tr -d ' ' || echo 0; }

# plugin NAME VERSION — a plugin root whose status line says which copy ran, what root it was
# handed and whether the payload reached it whole.
plugin() {
  local d="$WORK/$1"; mkdir -p "$d/.claude-plugin" "$d/skills/setup/references" "$d/hooks"
  printf '{"name":"devstride","version":"%s"}' "$2" > "$d/.claude-plugin/plugin.json"
  cat > "$d/skills/setup/references/statusline.sh" <<SH
#!/bin/bash
input=\$(cat)
case "\$input" in *'"marker":"whole"'*) seen=payload ;; *) seen=nopayload ;; esac
printf 'bar-$2 %s %s' "\$seen" "\$CLAUDE_PLUGIN_ROOT"
SH
  printf '%s' "$d"
}
loaded() { # loaded SESSION ROOT — the record the loaded copy's hook writes
  printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$1" \
    | CLAUDE_PLUGIN_ROOT="$2" "$REAL_PY" "$ROOT/hooks/session-runtime.py" record
}
registry() { # registry ROW... — rows are "scope|installPath|projectPath"
  "$REAL_PY" - "$REGISTRY" "$@" <<'PY'
import json, sys
rows = []
for spec in sys.argv[2:]:
    scope, path, project = spec.split("|")
    row = {"scope": scope, "installPath": path, "version": "0.0.0"}
    if project:
        row["projectPath"] = project
    rows.append(row)
json.dump({"version": 2, "plugins": {"devstride@devstride": rows}}, open(sys.argv[1], "w"))
PY
}
draw() { # draw SESSION CWD — what a person sees, colour stripped
  printf '{"session_id":"%s","marker":"whole","workspace":{"current_dir":"%s"}}' "$1" "$2" \
    | PATH="$WORK/bin:$PATH" /bin/bash "$L" 2>&1 | perl -pe 's/\e\[[0-9;]*m//g'
}

A="$(plugin old 3.1.0)"; B="$(plugin new 3.2.0)"
REPO="$WORK/repo"; mkdir -p "$REPO/sub"; git -C "$REPO" init -q; git -C "$REPO" checkout -q -b feature 2>/dev/null
OTHER="$WORK/other"; mkdir -p "$OTHER"; git -C "$OTHER" init -q

# (1) the session's record names the loaded copy: its status line runs, with the whole payload and
#     that copy as its plugin root, and no python is started
loaded s1 "$A"; : > "$PYLOG"
O="$(draw s1 "$REPO")"
if [ "$O" = "bar-3.1.0 payload $A" ] && [ "$(pyruns)" = 0 ]; then
  ok "(1) the launcher runs the loaded version's status line with the same payload, starting no python"
else bad "(1) got: $O pyruns=$(pyruns)"; fi

# (2) a second, newer installed version does not win over the one this session has loaded
registry "user|$B|"
O="$(draw s1 "$REPO")"
if [ "$O" = "bar-3.1.0 payload $A" ]; then
  ok "(2) another installed version in the registry does not replace the session's loaded one"
else bad "(2) got: $O"; fi

# (3) after an update and a reload, the next prompt rewrites the record and the bar follows it,
#     while a second session that has not reloaded keeps its own
loaded s2 "$A"; loaded s1 "$B"
O="$(draw s1 "$REPO")"; O2="$(draw s2 "$REPO")"
if [ "$O" = "bar-3.2.0 payload $B" ] && [ "$O2" = "bar-3.1.0 payload $A" ]; then
  ok "(3) a reloaded session moves to the new version; a session still on the old one stays there"
else bad "(3) got: $O | $O2"; fi

# (4) nothing to find — no record, no environment, no registry: the plain line, exit 0, no python
rm -f "$REGISTRY"; : > "$PYLOG"
O="$(draw nobody "$REPO")"; printf '{"session_id":"nobody"}' | /bin/bash "$L" >/dev/null 2>&1; RC=$?
mkdir -p "$WORK/plain dir"; O2="$(draw nobody "$WORK/plain dir")"
O3="$(printf 'not json' | (cd "$REPO" && /bin/bash "$L") 2>&1 | perl -pe 's/\e\[[0-9;]*m//g')"
if [ "$O" = "▣ repo · ⎇ feature" ] && [ "$RC" = 0 ] && [ "$O2" = "▣ plain dir" ] \
   && [ "$O3" = "▣ repo · ⎇ feature" ] && [ "$(pyruns)" = 0 ]; then
  ok "(4) no plugin copy anywhere → '▣ directory · ⎇ branch', never empty, never an error"
else bad "(4) got: $O | rc=$RC | $O2 | $O3 | pyruns=$(pyruns)"; fi

# (5) no record, but the environment names a plugin root
O="$(printf '{"session_id":"nobody","marker":"whole"}' | CLAUDE_PLUGIN_ROOT="$B" /bin/bash "$L" 2>&1)"
if [ "$O" = "bar-3.2.0 payload $B" ]; then ok "(5) without a record, \$CLAUDE_PLUGIN_ROOT is used"
else bad "(5) got: $O"; fi

# (6) no record: the registry's install for THIS repository wins over a user install, another
#     repository's install is never used, and the answer is kept so the next draw starts no python
registry "user|$A|" "project|$WORK/missing|$OTHER" "project|$B|$REPO"
: > "$PYLOG"; O="$(draw fresh "$REPO/sub")"; FIRST="$(pyruns)"; O2="$(draw fresh "$REPO/sub")"
O3="$(draw elsewhere "$OTHER")"
if [ "$O" = "bar-3.2.0 payload $B" ] && [ "$O2" = "$O" ] && [ "$FIRST" = 1 ] && [ "$(pyruns)" = 2 ] \
   && [ "$O3" = "bar-3.1.0 payload $A" ] && [ -f "$SESSIONS/fresh.root" ]; then
  ok "(6) registry: this repository's install first, another repository's never; one python start, then the kept answer"
else bad "(6) got: $O | $O2 | $O3 | first=$FIRST total=$(pyruns)"; fi

# (7) a record whose plugin copy has been removed falls through to the registry
GONE="$(plugin gone 3.0.0)"; loaded s7 "$GONE"; rm -rf "$GONE"
O="$(draw s7 "$REPO")"
if [ "$O" = "bar-3.2.0 payload $B" ]; then ok "(7) the loaded copy is gone from disk → the installed one runs"
else bad "(7) got: $O"; fi

# (8) a status line that prints nothing, or fails, still leaves a bar
BROKEN="$(plugin broken 3.3.0)"; printf '#!/bin/bash\nexit 3\n' > "$BROKEN/skills/setup/references/statusline.sh"
loaded s8 "$BROKEN"
O="$(draw s8 "$REPO")"; printf '{"session_id":"s8"}' | /bin/bash "$L" >/dev/null 2>&1; RC=$?
if [ "$O" = "▣ repo · ⎇ feature" ] && [ "$RC" = 0 ]; then
  ok "(8) the plugin's status line fails or prints nothing → the plain line, exit 0"
else bad "(8) got: $O rc=$RC"; fi

# (9) a plugin path that JSON escapes in the record is still found (through the python lookup)
ODD="$(plugin 'pläce' 3.4.0)"; loaded s9 "$ODD"; registry "user|$A|"
O="$(draw s9 "$REPO")"
if [ "$O" = "bar-3.4.0 payload $ODD" ]; then ok "(9) a non-ASCII plugin path in the record is read correctly"
else bad "(9) got: $O"; fi

# (10) the launcher's marker: its own, with a version, and one that NO released session-start hook
#      takes for a full copy — neither the first form (sed) nor the current one (python)
OLD_SED="$(sed -n 's/^# ds-statusline: managed v\([0-9][0-9.]*\) .*/\1/p' "$L" | head -1)"
OLD_RE="$("$REAL_PY" -c 'import re,sys
m = re.search(rb"^# ds-statusline: managed v([0-9]+(?:\.[0-9]+)*) .*$", open(sys.argv[1], "rb").read(), re.M)
print(m.group(1).decode() if m else "")' "$L")"
if sed -n 2p "$L" | grep -qE '^# ds-statusline-launcher: managed v[0-9]+ ' && [ -z "$OLD_SED" ] && [ -z "$OLD_RE" ]; then
  ok "(10) the launcher carries 'ds-statusline-launcher: managed v<n>', which an older plugin reads as not its own"
else bad "(10) line2=$(sed -n 2p "$L") sed=$OLD_SED re=$OLD_RE"; fi

# (11) the status line the plugin ships runs from the plugin and carries no managed marker
if ! grep -qE '^# ds-statusline(-launcher)?: managed' "$ROOT/skills/setup/references/statusline.sh" \
   && ! grep -qE 'BASH_SOURCE|\$0' "$ROOT/skills/setup/references/statusline.sh"; then
  ok "(11) the full status line has no managed marker and never reads its own location"
else bad "(11) the full status line carries a marker or derives a path from itself"; fi

# (12) end to end with the real status line: the launcher, run from a repository, shows the bar of
#      the plugin this working copy is
loaded real "$ROOT"
O="$(draw real "$REPO")"
if printf '%s' "$O" | grep -q '▣ repo · ⑂ main · ⎇ feature' && printf '%s' "$O" | grep -q '⊞ '; then
  ok "(12) launcher → the shipped status line: repository, checkout, branch and the plugin segment"
else bad "(12) got: $O"; fi

exit $FAIL
