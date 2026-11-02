#!/usr/bin/env python3
"""scripts/check-config-keys.py — every config key the shipped text cites must be registered.

CONTRIBUTING.md asks a maintainer to "walk the config keys, one by one": a skill that cites a key
nobody registered reads nothing and improvises, and nothing errors. This scan does the walk.

It reads README.md, CONTRIBUTING.md, skills/**/SKILL.md and skills/**/references/**/*.md, and:

  1. takes every backticked span that is exactly a dotted token — two or more segments of letters
     and digits, each starting with a letter (`review.localCommand`). Underscores are excluded on
     purpose: no config key has one, and GitHub API fields such as `head_commit.id` do;
  2. drops file-like tokens (the last segment is an extension: json, md, sh, py, yml, …) and the
     tokens listed in scripts/config-key-scan.ignore (each with its reason);
  3. requires each remaining token to equal a key in schemas/seam-registry.json, to be a prefix of
     one (an object such as `release.clearance`), or to be a suffix of one at a segment boundary
     (the relative forms references use, such as `fastStoryMerges.enabled`, `commands.owed`).
     Array steps (`[]`) in registered keys are ignored for this match;
  4. walks every ```json fenced block in a references file that parses as an object, and requires
     each key path under a registered top-level key to resolve to a registered key or to an object
     that holds one, and — in a fence with at least one registered top-level key, i.e. a config —
     every top-level key to be registered or on the ignore list (keys starting with `_` skipped; a path under a key registered as `any` or an untyped `array` is not walked).

Output: `CONFIG KEYS: ok (<n> tokens)`, or one `UNREGISTERED <file>:<line>: <token>` line per miss.
Usage: check-config-keys.py [--root <dir>]
Exit codes: 0 ok, 1 an unregistered token, 2 the registry or ignore file cannot be read.
"""
import json
import os
import re
import sys

FILE_EXTENSIONS = {"json", "md", "sh", "py", "yml", "yaml", "toml", "lock", "lockb", "nix", "mod",
                   "ts", "js", "com", "dev", "org", "io"}
TOKEN = re.compile(r"[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+")
SPAN = re.compile(r"`([^`\n]+)`")
FENCE = re.compile(r"^```json[ \t]*\n(.*?)^```", re.S | re.M)


def corpus(root):
    files = ["README.md", "CONTRIBUTING.md"]
    found = []
    for d, _, names in os.walk(os.path.join(root, "skills")):
        rel = os.path.relpath(d, root).replace(os.sep, "/")
        for name in names:
            path = rel + "/" + name
            if (name == "SKILL.md" and re.fullmatch(r"skills/[^/]+", rel)) or \
                    (name.endswith(".md") and re.match(r"skills/[^/]+/references(/|$)", rel)):
                found.append(path)
    files += sorted(found)
    return [f for f in files if os.path.isfile(os.path.join(root, f))]


def load(root):
    with open(os.path.join(root, "schemas/seam-registry.json"), encoding="utf-8") as f:
        reg = json.load(f)
    entries = [(e["key"], e.get("valueType")) for e in reg["hooks"]] + \
              [(e["key"], e.get("type")) for e in reg["settings"]]
    keys = {k.replace("[]", ""): t for k, t in entries}
    ignore = set()
    path = os.path.join(root, "scripts/config-key-scan.ignore")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    ignore.add(line.split()[0])
    return keys, ignore


def registered(token, keys):
    if token in keys:
        return True
    return any(k.startswith(token + ".") or k.endswith("." + token) for k in keys)


def opaque(path, keys):
    """True when an ancestor of path is registered with no walkable shape (any, plain array)."""
    parts = path.split(".")
    for i in range(1, len(parts)):
        t = keys.get(".".join(parts[:i]))
        if t in ("any", "array"):
            return True
    return False


def fence_paths(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if not isinstance(k, str) or k.startswith("_") or k == "$schema":
                continue
            path = "%s.%s" % (prefix, k) if prefix else k
            yield path, k
            yield from fence_paths(v, path)
    elif isinstance(obj, list):
        for item in obj:
            yield from fence_paths(item, prefix)


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if argv[:1] == ["--root"] and len(argv) == 2:
        root = os.path.abspath(argv[1])
    elif argv:
        print("usage: check-config-keys.py [--root <dir>]", file=sys.stderr)
        return 2
    try:
        keys, ignore = load(root)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print("check-config-keys: cannot read the registry or ignore file: %s" % exc, file=sys.stderr)
        return 2
    tops = {k.split(".")[0] for k in keys}
    misses, count = [], 0
    for rel in corpus(root):
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            text = f.read()
        lines = text.split("\n")
        for n, line in enumerate(lines, 1):
            for span in SPAN.findall(line):
                if not TOKEN.fullmatch(span):
                    continue
                if span.rsplit(".", 1)[1].lower() in FILE_EXTENSIONS or span in ignore:
                    continue
                count += 1
                if not registered(span, keys):
                    misses.append((rel, n, span))
        if "/references/" not in rel:
            continue
        for m in FENCE.finditer(text):
            try:
                obj = json.loads(m.group(1))
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            start = text.count("\n", 0, m.start(1)) + 1
            block = m.group(1).split("\n")
            config_like = any(k in tops for k in obj)
            for path, leaf in fence_paths(obj):
                if "." not in path:
                    # a top-level key: checked only in a fence that is a config (one registered
                    # top-level key or more), where an unregistered one would be read by nothing
                    if not config_like:
                        continue
                    count += 1
                    if path not in tops and path not in ignore:
                        offset = next((i for i, l in enumerate(block) if '"%s"' % leaf in l), 0)
                        misses.append((rel, start + offset, path))
                    continue
                if path.split(".")[0] not in tops:
                    continue
                count += 1
                if path in keys or opaque(path, keys) or \
                        any(k.startswith(path + ".") for k in keys):
                    continue
                offset = next((i for i, l in enumerate(block) if '"%s"' % leaf in l), 0)
                misses.append((rel, start + offset, path))
    for rel, n, token in misses:
        print("UNREGISTERED %s:%d: %s" % (rel, n, token))
    if not misses:
        print("CONFIG KEYS: ok (%d tokens)" % count)
    return 1 if misses else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
