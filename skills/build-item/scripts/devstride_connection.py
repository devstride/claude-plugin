#!/usr/bin/env python3
"""The one place this plugin finds a machine's DevStride API key, and the one way it calls a
DevStride tool outside the model — standard library only, importable, no command line.

There is one DevStride credential per agentic machine: the API key its DevStride connection
carries. The session reporter (hooks/presence-report.py) and the release clearance provider
(skills/release/scripts/clearance_core.py) both resolve it here, in one order:

  1. the environment: DEVSTRIDE_API_KEY, DEVSTRIDE_API_SECRET, DEVSTRIDE_ORG_ID (and the optional
     DEVSTRIDE_ORG_SLUG and DEVSTRIDE_BASE_URL);
  2. each KEY=VALUE file the caller names (only the clearance provider names one), filling only the
     names the environment left unset;
  3. the key the connection itself carries: the server named `devstride` in Claude Code's
     configuration file, first under the session's own project (each place of `project_places`, in
     order), then at user level. Its address and its three required headers are taken together
     from that one entry, never mixed with another source.

The first step that yields a key, a secret and an organization id wins. Rules for every source: the
key goes only to an https://api(-<stage>).devstride.(com|dev) host, redirects are refused, every
call is bounded in time, and no secret is ever printed, logged, put in an error, placed on a
command line or added to a child's environment. Nothing here writes a file.

DEVSTRIDE_PLUGIN_TEST_URL (http://127.0.0.1:<port>) exists for the tests only: it replaces the
base address, disables proxies, and makes an entry whose url is that address plus /mcp acceptable.
"""
import http.client
import json
import os
import re
import stat
import urllib.error
import urllib.request

BASE_URL_RULE = re.compile(r"^https://api(-[a-z0-9-]+)?\.devstride\.(com|dev)\Z")
CREDENTIAL_NAMES = ("DEVSTRIDE_API_KEY", "DEVSTRIDE_API_SECRET", "DEVSTRIDE_ORG_ID", "DEVSTRIDE_ORG_SLUG", "DEVSTRIDE_BASE_URL")
REQUIRED = CREDENTIAL_NAMES[:3]
DEFAULT_BASE = "https://api.devstride.com"
TEST_ENV = "DEVSTRIDE_PLUGIN_TEST_URL"
TEST_URL_RULE = re.compile(r"^http://(127\.0\.0\.1|localhost):[0-9]+$")
SERVER_NAME = "devstride"
CONFIG_LIMIT = 16 * 1048576
HEADERS = {"DEVSTRIDE_API_KEY": "x-devstride-api-key", "DEVSTRIDE_API_SECRET": "x-devstride-api-secret",
           "DEVSTRIDE_ORG_ID": "x-devstride-organization-id", "DEVSTRIDE_ORG_SLUG": "x-devstride-organization-slug"}
# readiness words: where a complete key was found, or why none was
READY_WORDS = ("environment", "file", "connection-project", "connection-user")


class Problem(Exception):
    """Every failure here: `text` is one secret-free line."""

    def __init__(self, text):
        super().__init__(text)
        self.text = text
        self.headers = None


class Missing(Problem):
    """No source yields a key, a secret and an organization id. `names` lists what is missing."""

    def __init__(self, names):
        super().__init__("DevStride credentials missing (%s)" % ", ".join(names))
        self.names = list(names)


class UnsafeFile(Problem):
    """A file that holds a key cannot be read safely. `kind` is `credentials` or `config`; `reason`
    is one of the fixed words below."""

    REASONS = ("mode too open", "not yours", "a link", "too large", "unreadable")

    def __init__(self, kind, path, reason):
        super().__init__("%s file %s cannot be read safely: %s" % (kind, path, reason))
        self.kind, self.path, self.reason = kind, path, reason


class BadAddress(Problem):
    """The base address is not a DevStride API host (or the tests-only address is malformed)."""


class Absent(Problem):
    """The server answered "Unknown tool": it has no such tool yet."""


class Refused(Problem):
    """HTTP 401 or 403: the server will not take this key."""

    def __init__(self, code):
        super().__init__("HTTP %d" % code)
        self.code = code


class Unavailable(Problem):
    """Everything else: unreachable, a timeout, another HTTP status, or an answer that is an error.
    `detail` carries the server's own error text when it gave one (never a secret of ours)."""

    def __init__(self, text, detail=None, code=None, unreachable=False):
        super().__init__(text)
        self.detail, self.code, self.unreachable = detail, code, unreachable


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def scrub(text, secrets=()):
    """The first line of `text`, with every secret replaced, cut to 300 characters."""
    first = (text or "").strip().splitlines()[0] if (text or "").strip() else ""
    for secret in secrets:
        if secret:
            first = first.replace(secret, "***")
    return first[:300]


def config_file(environ):
    """Claude Code's configuration file: where it keeps user-level and per-project MCP servers."""
    folder = environ.get("CLAUDE_CONFIG_DIR")
    return os.path.join(folder, ".claude.json") if folder else os.path.join(os.path.expanduser("~"), ".claude.json")


def main_checkout(top):
    """The main checkout of the repository `top` is a checkout of: `top` itself, or, for a linked
    worktree, the directory holding the shared .git. Claude Code keeps one project record per
    repository, the main checkout's. Read from the worktree's own pointer files; None on any doubt."""
    try:
        pointer = os.path.join(top, ".git")
        if os.path.isdir(pointer):
            return top
        with open(pointer) as handle:
            line = handle.read(4096).strip()
        if not line.startswith("gitdir:"):
            return None
        gitdir = line[7:].strip()
        gitdir = gitdir if os.path.isabs(gitdir) else os.path.join(top, gitdir)
        with open(os.path.join(gitdir, "commondir")) as handle:
            common = handle.read(4096).strip()
        common = os.path.realpath(common if os.path.isabs(common) else os.path.join(gitdir, common))
        return os.path.dirname(common) if os.path.basename(common) == ".git" else None
    except (OSError, ValueError):
        return None


def project_places(top, directory):
    """The project keys to look under, in order: the repository's main checkout, the checkout's own
    root, then the session's directory (real path, then as given). Outside a repository `top` is None."""
    places = []
    for place in ([main_checkout(top), top] if top else []) + [os.path.realpath(directory) if directory else None, directory]:
        if isinstance(place, str) and place and place not in places:
            places.append(place)
    return places


def owned_file(kind, path, limit=None, root_ok=False):
    """Open a file that may hold a key: a regular file the user owns (or root, with `root_ok`), not a
    link, with no group or other permission bits, at most `limit` bytes. Returns its bytes, None when there is no
    such file, and raises UnsafeFile otherwise."""
    try:
        info = os.lstat(path)
    except OSError:
        return None
    if stat.S_ISLNK(info.st_mode):
        raise UnsafeFile(kind, path, "a link")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        raise UnsafeFile(kind, path, "unreadable")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise UnsafeFile(kind, path, "a link")
        if info.st_uid != os.getuid() and not (root_ok and info.st_uid == 0):
            raise UnsafeFile(kind, path, "not yours")
        if info.st_mode & 0o077:
            raise UnsafeFile(kind, path, "mode too open")
        if limit is not None and info.st_size > limit:
            raise UnsafeFile(kind, path, "too large")
        chunks, size = [], 0
        while True:
            chunk = os.read(fd, 1048576)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if limit is not None and size > limit:
                raise UnsafeFile(kind, path, "too large")
        return b"".join(chunks)
    except OSError:
        raise UnsafeFile(kind, path, "unreadable")
    finally:
        os.close(fd)


def test_url(environ):
    """The tests-only base address, None when unset; a malformed one is refused, never used."""
    value = environ.get(TEST_ENV)
    if not value:
        return None
    if not TEST_URL_RULE.match(value):
        raise BadAddress("%s must be http://127.0.0.1:<port>" % TEST_ENV)
    return value


def entry_values(entry, test):
    """The key a `devstride` server entry carries, as {name: value, "base": address}; None unless its
    url is a DevStride API address followed by /mcp and it holds literal, non-empty values for the
    key, the secret and the organization id (header names compared without regard to case). A value
    containing `${` references an environment variable, which step 1 already covered: not a key."""
    if not isinstance(entry, dict) or not isinstance(entry.get("url"), str) or not isinstance(entry.get("headers"), dict):
        return None
    url = entry["url"]
    base = url[:-4] if url.endswith("/mcp") else None
    if not base or not (BASE_URL_RULE.match(base) or (test and base == test)):
        return None
    headers = {name.lower(): value for name, value in entry["headers"].items() if isinstance(name, str)}
    values = {}
    for name, header in HEADERS.items():
        value = headers.get(header)
        literal = isinstance(value, str) and value.strip() and "${" not in value
        if not literal and name in REQUIRED:
            return None
        values[name] = value.strip() if literal else ""
    values.update({"DEVSTRIDE_BASE_URL": base, "base": base})
    return values


_CONFIG = {}  # path -> (identity of the file read, its servers): a keeper re-reads only a changed file


def servers(config_path):
    """({project key: its devstride entry}, the user-level entry) from Claude Code's configuration
    file; ({}, None) when there is no file or it is not JSON. Raises UnsafeFile. Re-read only when
    the file's size, modification time or identity changed."""
    try:
        info = os.lstat(config_path)
        identity = (info.st_ino, info.st_size, info.st_mtime_ns, info.st_mode, info.st_uid)
    except OSError:
        _CONFIG.pop(config_path, None)
        return {}, None
    cached = _CONFIG.get(config_path)
    if cached and cached[0] == identity:
        if isinstance(cached[1], UnsafeFile):
            raise cached[1]
        return cached[1]
    try:
        raw = owned_file("config", config_path, CONFIG_LIMIT, root_ok=True)
    except UnsafeFile as error:
        _CONFIG[config_path] = (identity, error)
        raise
    found = ({}, None)
    try:
        data = json.loads(raw) if raw is not None else None
    except ValueError:
        data = None
    if isinstance(data, dict):
        projects = data.get("projects") if isinstance(data.get("projects"), dict) else {}
        own = {}
        for place, project in projects.items():
            listed = project.get("mcpServers") if isinstance(project, dict) else None
            if isinstance(listed, dict) and SERVER_NAME in listed:
                own[place] = listed[SERVER_NAME]
        listed = data.get("mcpServers")
        found = (own, listed.get(SERVER_NAME) if isinstance(listed, dict) else None)
    _CONFIG[config_path] = (identity, found)
    return found


def connection_key(config_path, places, test=None):
    """(the values of the first usable `devstride` entry, "connection-project" | "connection-user"),
    or (None, "no-key"). An entry that fails a rule is skipped and the next place is tried."""
    own, user = servers(config_path)
    for place in places:
        values = entry_values(own.get(place), test)
        if values:
            return values, "connection-project"
    values = entry_values(user, test)
    return (values, "connection-user") if values else (None, "no-key")


def read_credentials_file(path, values):
    """Fill the names `values` leaves empty from a KEY=VALUE file (a leading `export ` and quotes
    tolerated, comments skipped). Returns whether it filled a required name."""
    raw = owned_file("credentials", path)
    if raw is None:
        return False
    filled = False
    for line in raw.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[7:].strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        name, value = name.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if name in values and not values[name]:
            values[name] = value
            filled = filled or (name in REQUIRED and bool(value))
    return filled


def credentials(environ, config_path, places, files=()):
    """The machine's DevStride key, by the one resolution order: {the five names, "base", "test",
    "source"}. Raises Missing, UnsafeFile or BadAddress; never returns a partial key."""
    try:
        test, bad_test = test_url(environ), None
    except BadAddress as error:
        test, bad_test = None, error
    values = {name: environ.get(name) or "" for name in CREDENTIAL_NAMES}
    source = "environment"
    for path in files:
        if isinstance(path, str) and path and not all(values.values()) and read_credentials_file(path, values):
            source = "file"
    missing = [name for name in REQUIRED if not values[name]]
    if missing:
        try:
            entry, source = connection_key(config_path, places, test)
        except UnsafeFile as error:
            problem = Missing(missing)
            problem.unsafe = error
            raise problem
        if not entry:
            raise Missing(missing)
        values = {name: entry.get(name) or "" for name in CREDENTIAL_NAMES}
    if bad_test:
        raise bad_test
    base = values["DEVSTRIDE_BASE_URL"] or DEFAULT_BASE
    if test:
        base = test
    elif not BASE_URL_RULE.match(base):
        raise BadAddress("DEVSTRIDE_BASE_URL must be https://api.devstride.com (or an api-<stage>.devstride.com/.dev host)")
    return dict(values, base=base, test=bool(test), source=source)


def readiness(environ, config_path, places, files=()):
    """One fixed word, never a value: `environment`, `file`, `connection-project` or
    `connection-user` (where a complete key was found), else `unsafe-config` (Claude Code's
    configuration file cannot be read safely) or `no-key`."""
    try:
        return credentials(environ, config_path, places, files)["source"]
    except Missing as error:
        return "unsafe-config" if getattr(error, "unsafe", None) is not None else "no-key"
    except BadAddress:
        return "environment" if all(environ.get(name) for name in REQUIRED) else "no-key"
    except Problem:
        return "no-key"


def unsafe_reason(environ, config_path, places):
    """Why the configuration file cannot be read safely (an UnsafeFile), else None."""
    try:
        credentials(environ, config_path, places)
    except Missing as error:
        return getattr(error, "unsafe", None)
    except Problem:
        return None
    return None


def ready(environ, config_path, places, files=()):
    """Whether this machine's DevStride connection carries a key."""
    return readiness(environ, config_path, places, files) in READY_WORDS


def unwrap(reply):
    """The data of a JSON-RPC tools/call answer (plain JSON or text/event-stream). Raises Absent for
    "Unknown tool", else Unavailable (its `detail` the server's error text when it gave one)."""
    message = None
    try:
        message = json.loads(reply)
    except ValueError:
        for line in reply.splitlines():
            if line.startswith("data:"):
                try:
                    candidate = json.loads(line[5:].strip())
                except ValueError:
                    continue
                if isinstance(candidate, dict) and ("result" in candidate or "error" in candidate):
                    message = candidate
    if not isinstance(message, dict):
        raise Unavailable("DevStride returned something that is not a JSON-RPC answer")
    if isinstance(message.get("error"), dict):
        raise answer_error(str(message["error"].get("message") or ""))
    result = message.get("result")
    content = result.get("content") if isinstance(result, dict) else None
    text = content[0].get("text") if isinstance(content, list) and content and isinstance(content[0], dict) else None
    if not isinstance(text, str):
        raise Unavailable("DevStride returned an answer with no content")
    if result.get("isError"):
        raise answer_error(text)
    try:
        data = json.loads(text)
    except ValueError:
        raise Unavailable("DevStride returned an answer that is not JSON")
    return data["data"] if isinstance(data, dict) and "data" in data else data


def answer_error(text):
    if "Unknown tool:" in (text or ""):
        return Absent(text)
    return Unavailable("DevStride returned an error", detail=text or "")


def call_tool(name, arguments, creds, timeout=30, attempts=2):
    """POST one JSON-RPC tools/call to the hosted MCP address with the key's headers. Returns the
    answer's data. A network failure or an HTTP 5xx is tried again while attempts remain. Raises
    Refused (401, 403), Absent ("Unknown tool") or Unavailable; each carries the answer's `headers`
    when there was an answer."""
    headers = {"X-DevStride-Api-Key": creds["DEVSTRIDE_API_KEY"], "X-DevStride-Api-Secret": creds["DEVSTRIDE_API_SECRET"],
               "X-DevStride-Organization-Id": creds["DEVSTRIDE_ORG_ID"], "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}
    if creds.get("DEVSTRIDE_ORG_SLUG"):
        headers["X-DevStride-Organization-Slug"] = creds["DEVSTRIDE_ORG_SLUG"]
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}}).encode()
    handlers = [NoRedirect()] + ([urllib.request.ProxyHandler({})] if creds.get("test") else [])
    opener = urllib.request.build_opener(*handlers)
    reply, answer_headers = None, None
    for attempt in range(1, max(1, attempts) + 1):
        last = attempt >= max(1, attempts)
        try:
            request = urllib.request.Request(creds["base"] + "/mcp", data=body, headers=headers, method="POST")
            with opener.open(request, timeout=timeout) as response:
                reply, answer_headers = response.read().decode("utf-8", "replace"), response.headers
            break
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise Refused(error.code)
            if error.code >= 500 and not last:
                continue
            raise Unavailable("DevStride answered HTTP %d" % error.code, code=error.code)
        except (urllib.error.URLError, OSError, http.client.HTTPException):
            if not last:
                continue
            raise Unavailable("DevStride could not be reached", unreachable=True)
        except ValueError:
            raise Unavailable("the DevStride address is not a valid URL")
    try:
        return unwrap(reply)
    except Problem as error:
        error.headers = answer_headers
        raise
