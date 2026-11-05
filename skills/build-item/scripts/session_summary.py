#!/usr/bin/env python3
"""Scrub and bound one agent session summary before it leaves the machine — standard library only.

The rules are in `skills/build-item/references/session-summary.md`. Reads one JSON object on stdin,
prints the cleaned JSON object on stdout:

  * unknown keys are dropped, at every level;
  * every free-text value is scrubbed (secret shapes become `[redacted]`);
  * strings and lists are cut to the limits the summary store accepts;
  * a field with no usable value is omitted rather than sent empty.

Exit 0 with the JSON; exit 1 with a message on stderr when stdin is not a JSON object or lacks one
of the four required fields (itemNumber, sessionId, agent.name, startedAt).
"""
import json
import re
import sys

R = "[redacted]"

# Applied to every string, in this order.
BASIC = [
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)", re.S), R),
    (re.compile(r"\b([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@"), r"\1" + R + "@"),
    (re.compile(r"(?i)\b(authorization\s*[:=]\s*)(?:(bearer|basic|token)\s+)?[^\s\"']+"),
     lambda m: m.group(1) + (m.group(2) + " " if m.group(2) else "") + R),
    (re.compile(r"(?i)\b(Bearer|Basic)\s+(?=[A-Za-z0-9._~+/=-]*\d)[A-Za-z0-9._~+/=-]{8,}"), r"\1 " + R),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), R),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), R),
    (re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"), R),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{16,}"), R),
    (re.compile(r"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{8,}"), R),
    (re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{8,}"), R),
    (re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"), R),
    (re.compile(
        r"(?i)\b([A-Za-z0-9_.-]*(?:password|secret|token|api[_-]?key|access[_-]?key|private[_-]?key))"
        r"(\s*[=:]\s*)(\"[^\"]*\"|'[^']*'|\S+)"), r"\1\2" + R),
]
EMAIL = (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"), R)
# Bounded by any non-token character (quotes, backticks, brackets), but a dot only ends a word at a
# sentence's end: inside a file name it joins, so a long path is never redacted piecemeal.
LONG_WORD = re.compile(r"(?<![A-Za-z0-9+/=_.-])[A-Za-z0-9+/=_-]{32,}(?![A-Za-z0-9+/=_-]|\.\w)")
HEX = re.compile(r"^[0-9a-fA-F]+$")
SHA = re.compile(r"^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$")


def _long_word(m):
    w = m.group(0)
    if SHA.match(w):
        return w
    if re.search(r"[A-Z]", w) and re.search(r"[a-z]", w) and re.search(r"\d", w):
        return R
    if HEX.match(w) and re.search(r"\d", w) and re.search(r"[a-fA-F]", w):  # a hex key, not a commit hash
        return R
    return w


def scrub(text, prose=False, email=True):
    for rx, sub in BASIC:
        text = rx.sub(sub, text)
    if email:
        text = EMAIL[0].sub(EMAIL[1], text)
    if prose:
        text = LONG_WORD.sub(_long_word, text)
    return text


def clean(value, limit, prose=False, email=True):
    if not isinstance(value, str):
        return None
    value = scrub(value, prose, email).strip()[:limit]
    return value or None


def put(out, key, value):
    if value not in (None, "", [], {}):
        out[key] = value


def obj(src, spec):
    """spec: field -> (limit, prose, email). Returns the cleaned dict, or None when empty."""
    if not isinstance(src, dict):
        return None
    out = {}
    for field, (limit, prose, email) in spec.items():
        put(out, field, clean(src.get(field), limit, prose, email))
    return out or None


def str_list(src, limit, item_limit):
    if not isinstance(src, list):
        return None
    out = []
    for v in src:
        c = clean(v, item_limit)
        if c and c not in out:
            out.append(c)
        if len(out) >= limit:
            break
    return out or None


def build(src):
    if not isinstance(src, dict):
        raise ValueError("input must be a JSON object")
    out = {}
    put(out, "itemNumber", clean(src.get("itemNumber"), 32))
    put(out, "sessionId", clean(src.get("sessionId"), 200))
    put(out, "agent", obj(src.get("agent"), {"name": (100, False, True), "version": (100, False, True)}))
    put(out, "startedAt", clean(src.get("startedAt"), 40))
    # An identity the server resolves: an email here is the point, so it is not redacted.
    put(out, "directedBy", obj(src.get("directedBy"), {"username": (200, False, False), "email": (254, False, False)}))
    put(out, "model", obj(src.get("model"), {"name": (100, False, True), "version": (100, False, True)}))
    put(out, "intent", clean(src.get("intent"), 1000, prose=True))
    put(out, "branch", clean(src.get("branch"), 250))
    pr = src.get("pullRequest")
    if isinstance(pr, dict):
        o = {}
        if isinstance(pr.get("number"), int) and not isinstance(pr.get("number"), bool) and pr["number"] > 0:
            o["number"] = pr["number"]
        put(o, "url", clean(pr.get("url"), 500))
        put(out, "pullRequest", o)
    put(out, "filesTouched", str_list(src.get("filesTouched"), 200, 500))
    put(out, "toolsTouched", str_list(src.get("toolsTouched"), 100, 100))
    engines = []
    if isinstance(src.get("reviewEngines"), list):
        for e in src["reviewEngines"]:
            c = obj(e, {"name": (100, False, True), "outcome": (200, True, True)})
            if c and c.get("name"):
                engines.append(c)
            if len(engines) >= 10:
                break
    put(out, "reviewEngines", engines)
    put(out, "endedAt", clean(src.get("endedAt"), 40))
    if src.get("outcome") in ("completed", "failed", "interrupted"):
        out["outcome"] = src["outcome"]
    put(out, "errorReason", clean(src.get("errorReason"), 500, prose=True))
    put(out, "provider", clean(src.get("provider"), 100))
    put(out, "credentialName", clean(src.get("credentialName"), 200))
    missing = [k for k in ("itemNumber", "sessionId", "startedAt") if k not in out]
    if "name" not in out.get("agent", {}):
        missing.append("agent.name")
    if missing:
        raise ValueError("missing required: " + ", ".join(missing))
    return out


def main():
    try:
        out = build(json.load(sys.stdin))
    except (ValueError, json.JSONDecodeError) as e:
        print("session_summary: %s" % e, file=sys.stderr)
        return 1
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
