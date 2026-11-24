#!/usr/bin/env python3
"""The sign-in token for a repository's drill sessions (`drillSessions` in .claude/ds-config.json).

A repository that starts throwaway test sessions on purpose (drills that check its agent
tracking, for example) runs each in a Claude Code folder of its own, so none appears in the
person's Claude Code, and signs each in with a long-lived token the person makes once per machine
(`claude setup-token`). This script checks that token and, in the person's own terminal, makes it.

  drill-token.py check [--file <token file> | --config <ds-config path>]
  drill-token.py make  [--file <token file> | --config <ds-config path>]

`check` prints one verdict line, and on NOT READY a `Fix:` line after it:
  DRILL TOKEN: N/A (drillSessions not set)
  DRILL TOKEN: READY (<file>, signed in in a separate Claude Code folder)
  DRILL TOKEN: NOT READY — <reason>
  Fix: /devstride:setup drills        (make the token)
  Fix: run the check again later      (the service failed; the token was not refused)
  Fix: remove this machine's other Claude credential …  (an API key or key helper wins over the token)
  Fix: point drillSessions.tokenFile at …  (the path holds something else, which make never overwrites)
  Fix: put the claude command on PATH …
Exit 0 for READY and N/A, 1 for NOT READY, 2 for a usage or config error.
The token file must be an absolute or ~ path outside the repository, so it can never be committed.
The sign-in proof is one real, tiny request: `claude -p` on Haiku, with no tools, no settings, no
CLAUDE.md, no saved session and a one-line prompt, run in a fresh, empty Claude Code folder (the
folder is also its working directory, outside every repository) with the token in its environment,
never on a command line, and with no input. `claude auth status` alone cannot prove it: it reports
any token as signed in without asking the server; it is run only to confirm that the token, not some
other credential the machine supplies, is the one in use. The folder is removed afterwards, so the
request appears in no one's Claude Code. Only a 401 or 403 counts as the token being refused.

`make` runs only with a terminal on both stdin and stdout, so the token is typed where only the
person sees it and never enters an agent's transcript. It runs `claude setup-token` with the
terminal handed over, in a fresh, empty Claude Code folder of its own (also its working directory,
removed afterwards) and with no inherited Claude or Anthropic settings, so making the token can
never sign the person out of, or change, their own Claude Code. It asks for the token it printed
with a hidden prompt and saves it owner-only (proved first, so a mistyped paste never replaces a
working token; then written to a new 0600 file beside it and moved into place).

Never prints, logs or passes on the command line the token itself. Standard library only.
"""
import getpass
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

FIX = "Fix: /devstride:setup drills"
AGAIN = "Fix: run the check again later"
PATH_FIX = "Fix: put the claude command on PATH, then run the check again"
WRONG_FILE = "Fix: point drillSessions.tokenFile at the drill token's own file, or move this file away, then /devstride:setup drills"
TOKEN = re.compile(r"sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]+")  # what claude setup-token makes; nothing else is sent or overwritten
LIMIT = 4096  # a token is far shorter; a larger file is never read whole
OTHER = "Fix: remove this machine's other Claude credential (an API key or key helper), then run the check again"
PROOF = ["claude", "-p", "Reply with the word ok.", "--model", "haiku", "--tools", "", "--setting-sources", "user",
         "--strict-mcp-config", "--no-session-persistence", "--system-prompt", "Reply briefly.",
         "--output-format", "json"]


def usage(message):
    print("drill-token: %s" % message, file=sys.stderr)
    print("usage: drill-token.py check|make [--file <token file> | --config <ds-config path>]", file=sys.stderr)
    sys.exit(2)


def git_top(directory):
    try:
        return subprocess.run(["git", "-C", directory, "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, encoding="utf-8", errors="replace").stdout.strip()
    except OSError:
        return ""


def resolve(raw):
    raw = raw.strip()
    if not (raw.startswith("/") or raw.startswith("~") or (os.name == "nt" and os.path.isabs(raw))):
        usage("the token file must be an absolute or ~ path")
    path = os.path.abspath(os.path.expanduser(raw))
    folder = os.path.dirname(path)
    while folder and not os.path.isdir(folder):
        parent = os.path.dirname(folder)
        if parent == folder:  # the root of a drive that is not there (Windows): nothing above it
            usage("%s is on a drive or volume that is not available" % path)
        folder = parent
    if folder and git_top(folder):
        usage("%s is inside a git repository, where it could be committed; keep it outside" % path)
    return path


def repo_config():
    return os.path.join(git_top(os.getcwd()) or os.getcwd(), ".claude", "ds-config.json")


def token_file(args):
    """The token file to use, or None when the repository does not use drill sessions."""
    if len(args) == 2 and args[0] == "--file":
        return resolve(args[1])
    if len(args) == 2 and args[0] == "--config":
        config = args[1]
    elif not args:
        config = repo_config()
    else:
        usage("unknown arguments")
    try:
        with open(config, encoding="utf-8") as f:
            document = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        usage("cannot read %s: %s" % (config, error))
    block = document.get("drillSessions") if isinstance(document, dict) else None
    if block is None:
        return None
    path = block.get("tokenFile") if isinstance(block, dict) else None
    if not isinstance(path, str) or not path.strip():
        usage("drillSessions.tokenFile must name a file")
    return resolve(path)


def not_ready(reason, fix=FIX):
    print("DRILL TOKEN: NOT READY — %s" % reason)
    print(fix)
    return 1


def isolated_env(folder):
    """The environment for a claude run that must never touch the person's own Claude Code."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC"))}
    env["CLAUDE_CONFIG_DIR"] = folder
    return env


def which_claude():
    """The claude command's full path, or None. On Windows the lookup never tries the current
    directory, so a program named claude in the project being worked on never receives the token."""
    sys.dont_write_bytecode = True  # never leave compiled files in the installed plugin
    scripts = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "build-item/scripts")
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    import portable

    return portable.which("claude")


def claude(args):
    """args with claude resolved on Windows, where npm installs claude.cmd, which a bare name never finds."""
    return [which_claude() or "claude"] + args[1:] if os.name == "nt" else args


def run_claude(args, token, folder):
    env = isolated_env(folder)
    env["CLAUDE_CODE_OAUTH_TOKEN"] = token
    env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    result = subprocess.run(claude(args), env=env, cwd=folder, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
    try:
        answer = json.loads(result.stdout)
    except ValueError:
        answer = None
    return result.returncode, answer if isinstance(answer, dict) else None


def prove(token):
    """None when the token signs a fresh folder in, else (reason, fix line). Never echoes output."""
    if not which_claude():
        return "the claude command is not on PATH, so the token cannot be tried", PATH_FIX
    folder = tempfile.mkdtemp(prefix="drill-token-check-")
    try:
        try:
            code, status = run_claude(["claude", "auth", "status"], token, folder)
            method = status.get("authMethod") if status else None
            if code or method in (None, "", "none"):
                return "claude auth status gave no usable answer", AGAIN
            if method != "oauth_token":
                return "this machine supplies another credential ahead of the token, so it cannot be tried", OTHER
            code, answer = run_claude(PROOF, token, folder)
        except subprocess.TimeoutExpired:
            return "the sign-in request did not answer within 120 seconds", AGAIN
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    if answer is None:
        return "the sign-in request gave no readable answer (exit %d)" % code, AGAIN
    if code == 0 and answer.get("is_error") is False:
        return None
    http = answer.get("api_error_status")
    if http in (401, 403):
        return "the token was refused (HTTP %d); make a new one" % http, FIX
    reason = "HTTP %d" % http if isinstance(http, int) else "no status"
    return "the sign-in request failed for another reason (%s); the token was not refused" % reason, AGAIN


def check(path):
    if path is None:
        print("DRILL TOKEN: N/A (drillSessions not set)")
        return 0
    try:
        info = os.stat(path)
    except FileNotFoundError:
        return not_ready("no token file at %s; the person makes it once on this machine" % path)
    except OSError as error:
        return not_ready("cannot read %s (%s)" % (path, error.strerror), WRONG_FILE)
    if not stat.S_ISREG(info.st_mode):
        return not_ready("%s is not a file" % path, WRONG_FILE)
    fix = WRONG_FILE if holds_other(path) else FIX
    if info.st_mode & 0o077 and os.name != "nt":  # Windows reports 0o666 for every file: no mode bits to check
        return not_ready("%s can be read by others (mode %o); it must be owner-only (chmod 600)" % (path, stat.S_IMODE(info.st_mode)), fix)
    try:
        token = read_token(path)
    except (OSError, ValueError) as error:
        return not_ready("cannot read %s (%s)" % (path, getattr(error, "strerror", None) or "not a token-sized text file"), fix)
    if not token:
        return not_ready("%s is empty" % path)
    if not usable(token):
        return not_ready("%s does not hold one Claude Code token alone (sk-ant-oat01-…); nothing was sent" % path, WRONG_FILE)
    failed = prove(token)
    if failed:
        return not_ready(*failed)
    print("DRILL TOKEN: READY (%s, signed in in a separate Claude Code folder)" % path)
    return 0


def usable(token):
    """One Claude Code token and nothing else, so no other credential is ever sent or overwritten."""
    return TOKEN.fullmatch(token) is not None and token.count("sk-ant-") == 1


def read_token(path):
    """The file's text, stripped; ValueError when it is too large or not text."""
    with open(path, encoding="utf-8") as f:
        text = f.read(LIMIT + 1)
    if len(text) > LIMIT:
        raise ValueError("too large")
    return text.strip()


def holds_other(path):
    """True when the path exists and is anything but an empty file or a Claude Code token file."""
    try:
        if not stat.S_ISREG(os.stat(path).st_mode):
            return True
        content = read_token(path)
        return bool(content) and not usable(content)
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        return True


def save(path, token):
    folder = os.path.dirname(path)
    if not os.path.isdir(folder):
        os.makedirs(folder, mode=0o700)
    fd, temp = None, None
    for attempt in range(100):
        candidate = os.path.join(folder, ".%s.new-%d-%d" % (os.path.basename(path), os.getpid(), attempt))
        try:
            fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0), 0o600)
            temp = candidate
            break
        except FileExistsError:
            continue
    if fd is None:
        raise OSError("could not create a new file beside %s" % path)
    try:
        if hasattr(os, "fchmod"):  # Windows before Python 3.13 has none
            os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(token + "\n")
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def make(path):
    if path is None:
        print("DRILL TOKEN: N/A (drillSessions not set)")
        print("Set drillSessions.tokenFile first: /devstride:setup drills")
        return 2
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("drill-token: refused. Run this in your own terminal, not through an agent's prompt, so the "
              "token never enters a transcript.", file=sys.stderr)
        return 2
    if not which_claude():
        print("drill-token: the claude command is not on PATH.", file=sys.stderr)
        return 2
    if holds_other(path):
        print("drill-token: refused. %s already holds something that is not a Claude Code token; "
              "check drillSessions.tokenFile, or move that file away first." % path, file=sys.stderr)
        return 2
    print("Step 1 of 2: Claude Code makes a long-lived sign-in token (a browser page opens).")
    # A folder of its own: in the person's own Claude Code folder, the sign-in it starts can sign
    # them out of their everyday sessions.
    folder = tempfile.mkdtemp(prefix="drill-token-make-")
    try:
        result = subprocess.run(claude(["claude", "setup-token"]), env=isolated_env(folder), cwd=folder)
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    if result.returncode:
        print("drill-token: claude setup-token ended with exit %d; nothing was saved." % result.returncode, file=sys.stderr)
        return 1
    print("Step 2 of 2: paste the token it printed (it is not shown as you paste).")
    token = getpass.getpass("Token: ").strip()
    if not token or not usable(token):
        print("drill-token: that was not one Claude Code token (sk-ant-oat01-…); nothing was saved.", file=sys.stderr)
        return 1
    failed = prove(token)
    if failed:
        print("drill-token: not saved, so any token already there is kept.", file=sys.stderr)
        return not_ready(*failed)
    save(path, token)
    print("Saved to %s, owner-only." % path)
    return check(path)


def main(argv):
    if not argv or argv[0] not in ("check", "make"):
        usage("say check or make")
    path = token_file(argv[1:])
    return check(path) if argv[0] == "check" else make(path)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
