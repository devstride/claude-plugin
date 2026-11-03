#!/bin/bash
# scripts/check-train-name.sh [--root <dir>] — the old config name `supportTrain` appears in skill
# text only where the rename is explained: the config-defaults key table, doctor's note, the
# release-train pull-request search (both spellings) and the generated key table. Everywhere else
# a skill says `releaseTrain`. Prints each stray hit; exit 1 on any.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "${1:-}" = "--root" ] && { ROOT="$2"; shift 2; }
ALLOW="skills/setup/references/config-defaults.md skills/doctor/SKILL.md skills/setup/references/seam-registry.md"
BAD=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  case " $ALLOW " in *" $rel "*) continue ;; esac
  if grep -n 'supportTrain' "$f" >/dev/null 2>&1; then
    grep -n 'supportTrain' "$f" | sed "s#^#$rel:#"; BAD=1
  fi
done < <(find "$ROOT/skills" -type f -name '*.md')
[ "$BAD" = 0 ] && echo "train name: ok" || echo "train name: skill text names supportTrain outside the files that explain the rename" >&2
exit "$BAD"
