#!/usr/bin/env python3
"""Tell an item's author when its change could cost money, cut someone off or break a caller.

The single implementation of `references/consequence-notices.md`. A notice, never a gate: nothing
this file answers stops a build, review, merge or release.

The judgment (does this diff add billable infrastructure?) is the agent's. This file does the parts
that must not depend on judgment:

- the categories in force: the four defaults plus the repository's own
  (`consequenceNotices.categories`);
- evidence: every finding names a file and lines the final diff actually changed, on the side it
  changed them (`new` for added lines, `old` for removed ones), so a notice never cites code the
  change did not touch;
- the comment: one internal DevStride comment in one fixed shape that @-mentions the item's author
  and anyone `consequenceNotices.notify` names, and the recap lines that repeat it;
- whether to post at all: no finding and no earlier notice → nothing; the same notice already on
  the item → nothing; an earlier notice the final diff no longer supports → a short withdrawal;
- collecting the newest notice per item for a release's recap.

  check    stdin {"item", "head", "base"?, "diff"?, "findings": [{"category", "file", "lines",
                  "side"?, "sentence"}], "author"?: {"username", "name"},
                  "notify"?: [{"username", "name"}], "earlier": [<comment>...], "config"?}
           stdout {"post", "notices": [...], "comment": {"html"} | null, "recap": [...], "reason"}
  collect  stdin {"items": [{"number", "comments": [<comment html or {"html"}>...]}], "config"?}
           stdout {"notices": [{"item", "lines": [...], "findings": [{"title", "file", "where",
                  "removed", "sentence"}]}], "recap": [...], "reason"}
  doctor   [--config <path>]  one line per finding, `OK`/`WARN`/`ERROR`; exit 1 on an ERROR

`diff` is the output of `git diff --unified=0` between the working base and the final reviewed
head. Absent, `check` runs that itself in the current directory:
`git diff --unified=0 --no-color --no-ext-diff --no-textconv --inter-hunk-context=0 --src-prefix=a/
--dst-prefix=b/ -M <base>...<head>` (`base` is then required).
`lines` is "40", "40-52" or "40-42, 50", and every line it names must be one the diff changed on
that side; it is left out only for a renamed file (cite the old path), a binary file or a file
whose only change is its mode (an executable bit). `config` replaces reading `.claude/ds-config.json`. `earlier` is every
comment already on the item (oldest first); comments that are not notices are ignored.

Exit 0 with an answer, 2 with one `consequence-notices: <reason>` line on stderr (a bad request, a
finding whose evidence the diff does not hold, a bad configuration), 1 for anything else.
"""
import html
import json
import os
import re
import subprocess
import sys

DEFAULTS = [
    {"id": "billable-infrastructure", "title": "Adds billable infrastructure",
     "means": "a new cloud resource, managed service or paid plan, or more of one that is charged by "
              "size, count or use"},
    {"id": "removed-caller-surface", "title": "Removes something callers still use",
     "means": "an endpoint, route, webhook, event, tool, command, export or documented URL is deleted "
              "or stops being served while callers outside this change may still use it"},
    {"id": "access-removed", "title": "Removes someone's access",
     "means": "a person, team, customer or service loses access to a resource they had: a narrowed "
              "permission, role, policy, sharing rule, allow list, token scope or membership"},
    {"id": "interface-break", "title": "Could break a published interface",
     "means": "the shape, meaning, validation, authentication, limits, errors or timing of an API, "
              "webhook, tool, command or documented URL changes so existing callers may stop "
              "working correctly"},
]
MARK = "Consequence notice"
ITEM = re.compile(r"^I\d+$")
SHA = re.compile(r"^[0-9a-f]{7,40}$")
CAT_ID = re.compile(r"^[a-z][a-z0-9-]{1,40}$")
RANGE = re.compile(r"^\s*(\d+)\s*(?:[-–]\s*(\d+))?\s*$")
BINARY = re.compile(r"^Binary files (.+?) and (.+) differ$")
HEADLINE = re.compile(r"^Consequence notice for (I\d+) at reviewed head ([0-9a-f]{7,40})\s*:\s*(none\.)?")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
TAGS = re.compile(r"<[^>]*>")
LI = re.compile(r"<li\b[^>]*>(.*?)</li\s*>", re.I | re.S)


class Refuse(Exception):
    pass


def need(cond, reason):
    if not cond:
        raise Refuse(reason)


INLINE = re.compile(r"</?(?:strong|code|em|b|i|span|a|user-mention-popup)\b[^>]*>", re.I)


def text_of(fragment):
    """Plain text: inline tags vanish (so "<code>x</code>:" reads "x:"), block tags break words."""
    return re.sub(r"\s+", " ", html.unescape(TAGS.sub(" ", INLINE.sub("", fragment)))).strip()


# ---- configuration ------------------------------------------------------------------------------

def read_config(path=None):
    path = path or os.path.join(".claude", "ds-config.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise Refuse("cannot read %s: %s" % (path, e))
    need(isinstance(data, dict), "%s is not a JSON object" % path)
    return data


def settings(config):
    """(enabled, categories, notify, problems) from a whole ds-config; problems are (level, text)."""
    block = config.get("consequenceNotices")
    problems = []
    if block is None:
        return True, list(DEFAULTS), [], problems
    if not isinstance(block, dict):
        return True, list(DEFAULTS), [], [("ERROR", "consequenceNotices must be an object")]
    enabled = block.get("enabled", True)
    if not isinstance(enabled, bool):
        problems.append(("ERROR", "consequenceNotices.enabled must be true or false"))
        enabled = True
    cats = list(DEFAULTS)
    seen = {c["id"] for c in DEFAULTS}
    extra = block.get("categories", [])
    if not isinstance(extra, list):
        problems.append(("ERROR", "consequenceNotices.categories must be a list"))
        extra = []
    for i, c in enumerate(extra):
        where = "consequenceNotices.categories[%d]" % i
        if not isinstance(c, dict):
            problems.append(("ERROR", "%s must be an object with id, title and means" % where))
            continue
        cid, title, means = c.get("id"), c.get("title"), c.get("means")
        if not (isinstance(cid, str) and CAT_ID.match(cid)):
            problems.append(("ERROR", "%s.id must be lower-case words joined by hyphens" % where))
            continue
        if cid in seen:
            problems.append(("ERROR", "%s.id %r is already a category" % (where, cid)))
            continue
        if not (isinstance(title, str) and title.strip() and "\n" not in title and len(title) <= 80):
            problems.append(("ERROR", "%s.title must be one line of at most 80 characters" % where))
            continue
        if not (isinstance(means, str) and means.strip()):
            problems.append(("ERROR", "%s.means must say what the category covers" % where))
            continue
        seen.add(cid)
        cats.append({"id": cid, "title": title.strip(), "means": means.strip()})
    notify = block.get("notify", [])
    if not (isinstance(notify, list) and all(isinstance(n, str) and n.strip() for n in notify)):
        problems.append(("ERROR", "consequenceNotices.notify must be a list of DevStride users"))
        notify = []
    return enabled, cats, [n.strip() for n in notify], problems


# ---- the diff -----------------------------------------------------------------------------------

ESCAPES = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}


def unquote(path, prefixed=True):
    """git's C-style quoting of unusual paths ("caf\\303\\251\\tx"), then the a/ or b/ prefix that
    only the ---, +++ and Binary lines carry (`prefixed`). Octal escapes are UTF-8 bytes."""
    if len(path) > 1 and path.startswith('"') and path.endswith('"'):
        body, out, i = path[1:-1], bytearray(), 0
        while i < len(body):
            ch = body[i]
            if ch == "\\" and i + 1 < len(body):
                nxt = body[i + 1]
                if nxt in "01234567" and i + 3 < len(body) and all(c in "01234567" for c in body[i + 1:i + 4]):
                    out.append(int(body[i + 1:i + 4], 8) & 0xFF)
                    i += 4
                    continue
                if nxt in ESCAPES:
                    out.append(ESCAPES[nxt])
                    i += 2
                    continue
            out += ch.encode("utf-8")
            i += 1
        path = out.decode("utf-8", "replace")
    if path == "/dev/null":
        return None
    return path[2:] if prefixed and path[:2] in ("a/", "b/") else path


def entry(files, path):
    return files.setdefault(path, {"old": set(), "new": set(), "renamedTo": None, "binary": False,
                                   "mode": None, "whole": None})


def git_header_path(rest):
    """The path of `diff --git a/P b/P` when both sides name the same file (a mode-only change)."""
    if rest.startswith('"'):
        m = re.match(r'^("(?:[^"\\]|\\.)*") ("(?:[^"\\]|\\.)*")$', rest)
        if m:
            a, b = unquote(m.group(1)), unquote(m.group(2))
            return a if a == b else None
        return None
    n = (len(rest) - 5) // 2
    p = rest[2:2 + n]
    return p if n > 0 and rest == "a/%s b/%s" % (p, p) else None


def changed_lines(diff):
    """{path: {"old", "new", "renamedTo", "binary"}}: the lines a unified=0 diff removed and added,
    where a path was renamed to, and whether it is a binary file (no lines to cite)."""
    files, old, new, header, moved_from, moved_to, same, modes = {}, None, None, False, None, None, None, {}
    oline = nline = 0
    for line in diff.split("\n"):  # never splitlines(): a form feed or U+2028 inside a line is content
        if line.startswith("diff --git "):
            old = new = moved_from = moved_to = None
            modes = {}
            same = git_header_path(line[11:])
            header = True  # until the first hunk: a removed line "-- x" reads "--- x" in a hunk
        elif header and same and (line.startswith("new file mode ") or line.startswith("deleted file mode ")):
            entry(files, same)["whole"] = "file added" if line.startswith("new") else "file deleted"
        elif header and (line.startswith("old mode ") or line.startswith("new mode ")):
            modes[line[:3]] = line[9:].strip()
            if "old" in modes and "new" in modes and same:
                entry(files, same)["mode"] = "%s → %s" % (modes["old"], modes["new"])
        elif header and line.startswith("--- "):
            old = unquote(line[4:].split("\t")[0])
        elif header and line.startswith("+++ "):
            new = unquote(line[4:].split("\t")[0])
            for p in (old, new):
                if p:
                    entry(files, p)
        elif header and line.startswith("rename from "):
            moved_from = unquote(line[12:], prefixed=False)
            entry(files, moved_from)
        elif header and line.startswith("rename to "):
            to = unquote(line[10:], prefixed=False)
            entry(files, to)
            moved_to = to
            if moved_from:
                files[moved_from]["renamedTo"] = to
        elif header and BINARY.match(line):
            # The diff --git line (or the rename) names the paths; the Binary line is ambiguous when
            # a path holds " and ", so it is only the fallback.
            known = [p for p in (same, moved_from, moved_to) if p]
            if not known:
                a, b = BINARY.match(line).groups()
                known = [p for p in (unquote(a), unquote(b)) if p]
            for p in known:
                entry(files, p)["binary"] = True
        else:
            m = HUNK.match(line)
            if m and (old or new):
                # Count the lines themselves, never the hunk's span: a hunk may carry unchanged
                # context (diff.interHunkContext), which is not evidence.
                header = False
                oline, nline = int(m.group(1)), int(m.group(3))
            elif not header and (old or new) and line[:1] in ("-", "+", " "):
                if line[0] == "-":
                    if old:
                        files[old]["old"].add(oline)
                    oline += 1
                elif line[0] == "+":
                    if new:
                        files[new]["new"].add(nline)
                    nline += 1
                else:
                    oline += 1
                    nline += 1
    return files


def run_diff(base, head):
    need(isinstance(base, str) and base.strip(), "base is required when diff is absent")
    p = subprocess.run(["git", "-c", "core.quotePath=false", "diff", "--unified=0", "--no-color",
                        "--no-ext-diff", "--no-textconv", "--inter-hunk-context=0", "--src-prefix=a/", "--dst-prefix=b/",
                        "-M", "%s...%s" % (base, head)], capture_output=True)
    err = p.stderr.decode("utf-8", "replace").strip()[:200]
    need(p.returncode == 0, "git diff %s...%s failed: %s" % (base, head, err))
    return p.stdout.decode("utf-8", "replace")  # a Latin-1 file in the diff is not a crash


# ---- check --------------------------------------------------------------------------------------

def mention(user):
    need(isinstance(user, dict) and isinstance(user.get("username"), str) and user["username"].strip()
         and isinstance(user.get("name"), str) and user["name"].strip(),
         "each person needs a username and a name")
    u, n = html.escape(user["username"].strip()), html.escape(user["name"].strip())
    return ('<user-mention-popup data-mention="" class="mention" data-id="%s" data-label="%s">@%s'
            '</user-mention-popup>' % (u, n, n))


def where_html(where):
    """The where part, with a rename target in <code> so a colon in a path never ends it."""
    if where.startswith("renamed to "):
        return "renamed to <code>%s</code>" % html.escape(where[len("renamed to "):])
    return html.escape(where)


def entry_text(title, finding):
    side = " (removed)" if finding["side"] == "old" else ""
    return "%s — %s %s%s: %s" % (title, finding["file"], finding["where"], side, finding["sentence"])


def parse_ranges(text):
    """"40", "40-52" or "40-42, 50" → [(40, 42), (50, 50)]; None when it does not parse."""
    out = []
    for part in str(text).split(","):
        m = RANGE.match(part)
        if not m:
            return None
        lo, hi = int(m.group(1)), int(m.group(2) or m.group(1))
        if not 1 <= lo <= hi:
            return None
        out.append((lo, hi))
    merged = []
    for lo, hi in sorted(out):  # one canonical form: "50, 40-41, 42" and "40-42, 50" are the same
        if merged and lo <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(hi, merged[-1][1]))
        else:
            merged.append((lo, hi))
    return merged or None


def validate(findings, cats, files):
    by_id = {c["id"]: c for c in cats}
    out = []
    need(isinstance(findings, list), "findings must be a list (empty when there are none)")
    for i, f in enumerate(findings):
        where = "finding %d" % (i + 1)
        need(isinstance(f, dict), "%s must be an object" % where)
        cat = f.get("category")
        need(cat in by_id, "%s: unknown category %r (known: %s)" % (where, cat, ", ".join(by_id)))
        path = f.get("file")
        need(isinstance(path, str) and path in files, "%s: %r is not a file this diff changes" % (where, path))
        side = f.get("side", "new")
        need(side in ("new", "old"), "%s: side must be new or old" % where)
        info = files[path]
        if f.get("lines") in (None, ""):
            # Whole-file evidence: only a rename (cite the old path) or a binary file has no lines.
            empty = info["whole"] and not info["old"] and not info["new"]  # an empty file has no lines
            need(info["renamedTo"] or info["binary"] or info["mode"] or empty,
                 "%s: %s needs the changed lines it cites (only a renamed, binary, mode-changed or "
                 "empty added or deleted file has none)" % (where, path))
            need(not (info["whole"] == "file added" and side == "old")
                 and not (info["whole"] == "file deleted" and side == "new"),
                 "%s: %s was %s by this diff, so its side is %s" % (
                     where, path, info["whole"] and info["whole"].split()[1],
                     "new" if info["whole"] == "file added" else "old"))
            label = (("renamed to %s" % info["renamedTo"]) if info["renamedTo"] else
                     "(binary file)" if info["binary"] else
                     "(mode %s)" % info["mode"] if info["mode"] else "(%s)" % info["whole"])
            spans, shown = [], label
        else:
            spans = parse_ranges(f["lines"])
            need(spans, "%s: lines must be like 40, 40-52 or 40-42, 50" % where)
            changed = info[side]
            for lo, hi in spans:
                missing = [n for n in range(lo, hi + 1) if n not in changed]
                need(not missing, "%s: %s line %d was not %s by this diff" % (
                    where, path, missing[0] if missing else lo,
                    "removed" if side == "old" else "added or changed"))
            parts = ["%d" % lo if lo == hi else "%d–%d" % (lo, hi) for lo, hi in spans]
            single = len(spans) == 1 and spans[0][0] == spans[0][1]
            shown = ("line " if single else "lines ") + ", ".join(parts)
        sentence = f.get("sentence")
        need(isinstance(sentence, str) and sentence.strip() and "\n" not in sentence and len(sentence) <= 300,
             "%s: sentence must be one plain line of at most 300 characters" % where)
        out.append({"category": cat, "title": by_id[cat]["title"], "file": path, "side": side,
                    "lines": ", ".join("%d" % lo if lo == hi else "%d-%d" % (lo, hi) for lo, hi in spans),
                    "where": shown, "sentence": sentence.strip()})
    return out


def comment_html(comment):
    """A comment's HTML: a string, {"html"}, or a list_comments row ({"message": {"html"} | text})."""
    if isinstance(comment, str):
        return comment
    if isinstance(comment, dict):
        if isinstance(comment.get("html"), str):
            return comment["html"]
        msg = comment.get("message")
        if isinstance(msg, dict) and isinstance(msg.get("html"), str):
            return msg["html"]
        if isinstance(msg, str):
            return msg
    raise Refuse("a comment must be its HTML, {\"html\"} or a list_comments row with message.html")


FINDING = re.compile(r"^\s*<strong>(.*?)</strong>\s*—\s*<code>(.*?)</code>\s*((?:<code>.*?</code>|[^:<]|<(?!code)[^>]*>)*?):\s*(.*)$", re.S)


def findings_in(raw):
    """The notice's findings as data, for a release's reconcile: [{title, file, where, removed,
    sentence}] read back from the shape this file renders."""
    out = []
    for li in LI.findall(raw):
        m = FINDING.match(li)
        if m:
            where = text_of(m.group(3))
            removed = where.endswith("(removed)")
            out.append({"title": text_of(m.group(1)), "file": html.unescape(m.group(2)),
                        "where": where[:-len("(removed)")].strip() if removed else where,
                        "removed": removed, "sentence": text_of(m.group(4))})
    return out


def notices_in(comment, item):
    """None when the comment is not this item's notice; else its entries' text ([] = withdrawn).

    Only the shape this file renders counts: "Consequence notice for <item> at reviewed head
    <sha>:" then a list, or "...: none." for a withdrawal. A reply that merely starts with the
    words, or a notice for another item, is not one."""
    raw = comment_html(comment)
    m = HEADLINE.match(text_of(raw))
    if not m or m.group(1) != item:
        return None
    if m.group(3):
        return []
    found = [text_of(li) for li in LI.findall(raw)]
    return found or None


def same_findings(found, last):
    """The earlier notice says exactly these findings, in any order. The sentence counts: a notice
    whose facts changed on the same lines (a limit of 10 that became 50) is posted again, newest wins."""
    return sorted(text_of(html.escape(entry_text(f["title"], f))) for f in found) == sorted(last)


def check(req):
    need(isinstance(req, dict), "the request must be a JSON object")
    item, head = req.get("item"), req.get("head")
    need(isinstance(item, str) and ITEM.match(item), "item must be a number like I20100")
    need(isinstance(head, str) and SHA.match(head), "head must be a commit SHA")
    config = req["config"] if "config" in req else read_config()
    need(isinstance(config, dict), "config must be an object")
    enabled, cats, _, problems = settings(config)
    errors = [t for lvl, t in problems if lvl == "ERROR"]
    need(not errors, errors[0] if errors else "")
    if not enabled:
        return {"post": False, "notices": [], "comment": None, "recap": [],
                "reason": "consequence notices are off (consequenceNotices.enabled is false)"}
    diff = req.get("diff")
    if diff is None:
        diff = run_diff(req.get("base"), head)
    need(isinstance(diff, str), "diff must be text")
    found = validate(req.get("findings"), cats, changed_lines(diff))
    entries = [entry_text(f["title"], f) for f in found]
    earlier = req.get("earlier")
    need(isinstance(earlier, list), "earlier must be the item's comments (a list, empty when it has none): "
         "without them a notice is never withdrawn and never deduplicated")
    last = None
    for c in earlier:
        n = notices_in(c, item)
        if n is not None:
            last = n
    short = head[:7]
    if not entries and not last:
        return {"post": False, "notices": [], "comment": None, "recap": [],
                "reason": "no finding at %s, so no notice" % short}
    if last is not None and same_findings(found, last):
        return {"post": False, "notices": found, "comment": None,
                "recap": ["%s %s: %s" % (MARK, item, e) for e in entries],
                "reason": "the same notice is already on %s" % item}
    people = [req.get("author")] if req.get("author") is not None else []
    notify = req.get("notify", [])
    need(isinstance(notify, list), "notify must be a list of people")
    people += notify
    seen, tags = set(), []
    for p in people:
        tag = mention(p)
        if p["username"].strip().lower() not in seen:
            seen.add(p["username"].strip().lower())
            tags.append(tag)
    to = (" " + " ".join(tags)) if tags else ""
    if not entries:
        body = ("<p><strong>%s</strong> for %s at reviewed head <code>%s</code>: none.%s</p>"
                "<p>The earlier notice no longer applies: the final change does none of those things.</p>"
                % (MARK, item, short, to))
        return {"post": True, "notices": [], "comment": {"html": body},
                "recap": ["%s %s: withdrawn, the final change no longer does what the earlier notice said"
                          % (MARK, item)],
                "reason": "the earlier notice no longer applies at %s" % short}
    lis = "".join("<li><strong>%s</strong> — <code>%s</code> %s%s: %s</li>"
                  % (html.escape(f["title"]), html.escape(f["file"]), where_html(f["where"]),
                     " (removed)" if f["side"] == "old" else "", html.escape(f["sentence"]))
                  for f in found)
    body = ("<p><strong>%s</strong> for %s at reviewed head <code>%s</code>:%s</p>"
            "<p>This change may affect people or systems outside this work. It is a notice, not a stop: "
            "the build, review, merge and release carry on.</p><ul>%s</ul>" % (MARK, item, short, to, lis))
    return {"post": True, "notices": found, "comment": {"html": body},
            "recap": ["%s %s: %s" % (MARK, item, e) for e in entries],
            "reason": "%d notice(s) at %s" % (len(found), short)}


# ---- collect ------------------------------------------------------------------------------------

def collect(req):
    need(isinstance(req, dict) and isinstance(req.get("items"), list), "items must be a list")
    config = req["config"] if "config" in req else read_config()
    need(isinstance(config, dict), "config must be an object")
    enabled, _, _, problems = settings(config)
    errors = [t for lvl, t in problems if lvl == "ERROR"]
    need(not errors, errors[0] if errors else "")
    if not enabled:
        return {"notices": [], "recap": [], "reason": "consequence notices are off (consequenceNotices.enabled is false)"}
    notices, recap = [], []
    for it in req["items"]:
        need(isinstance(it, dict) and isinstance(it.get("number"), str) and ITEM.match(it["number"]),
             "each item needs a number like I20100")
        comments = it.get("comments", [])
        need(isinstance(comments, list), "%s: comments must be a list (oldest first)" % it["number"])
        last, last_findings = None, []
        for c in comments:
            n = notices_in(c, it["number"])
            if n is not None:
                last, last_findings = n, findings_in(comment_html(c))
        if last:
            notices.append({"item": it["number"], "lines": last, "findings": last_findings})
            recap += ["%s %s: %s" % (MARK, it["number"], line) for line in last]
    return {"notices": notices, "recap": recap,
            "reason": "%d item(s) with a standing notice" % len(notices)}


# ---- doctor -------------------------------------------------------------------------------------

def doctor(argv):
    path = None
    if argv[:1] == ["--config"] and len(argv) == 2:
        path = argv[1]
    elif argv:
        raise Refuse("doctor takes only --config <path>")
    config = read_config(path)
    enabled, cats, notify, problems = settings(config)
    for lvl, t in problems:
        print("%s %s" % (lvl, t))
    if any(lvl == "ERROR" for lvl, _ in problems):
        return 1
    if "consequenceNotices" not in config:
        print("OK consequenceNotices: not set, the four default categories notify the item's author")
    else:
        print("OK consequenceNotices: %s, %d categories, notifying the item's author%s"
              % ("on" if enabled else "off", len(cats),
                 (" and " + ", ".join(notify) + " (resolve each in DevStride)") if notify else ""))
    return 1 if any(lvl == "ERROR" for lvl, _ in problems) else 0


def main(argv):
    if not argv or argv[0] not in ("check", "collect", "doctor"):
        print("usage: consequence-notices.py check|collect|doctor", file=sys.stderr)
        return 2
    try:
        if argv[0] == "doctor":
            return doctor(argv[1:])
        need(len(argv) == 1, "%s reads its request from stdin and takes no arguments" % argv[0])
        try:
            req = json.load(sys.stdin)
        except ValueError as e:
            raise Refuse("the request is not JSON: %s" % e)
        out = check(req) if argv[0] == "check" else collect(req)
    except Refuse as e:
        print("consequence-notices: %s" % e, file=sys.stderr)
        return 2
    json.dump(out, sys.stdout, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
