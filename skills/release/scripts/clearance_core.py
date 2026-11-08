"""The release clearance verbs, shared by the two built-in providers. clearance-github.sh and
clearance-devstride.sh are thin wrappers: `python3 clearance_core.py <provider> <verb> ...`. The
store (where the one record lives, and how it moves atomically) is the only thing that differs;
every verdict line, exit code and local file is this file's, so the providers cannot drift. The
contract is skills/release/references/clearance.md."""
import hashlib, http.client, json, os, re, secrets, signal, subprocess, sys, time, urllib.error, urllib.request
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "build-item", "scripts"))
import claim_record  # noqa: E402  the one machine and session naming every claim uses

RECORD_VERSION = 1
DEFAULT_REF = "refs/clearance/release"
DEFAULT_STALE_MINUTES = 20
DEFAULT_WAIT_MINUTES = 180
DEFAULT_HOTFIX_PATTERN = "*/hotfix/**"
# Minutes a phase may run before status calls it STUCK. Only phases that should finish in a
# bounded time have one: review and train wait on people and CI, so they have none by default.
DEFAULT_PHASE_BUDGETS = {"pre-ship": 120, "deploy": 60, "close-out": 45}
PR_LIMIT = 200  # a list this long is reported as truncated rather than trusted
SHELLS = {"sh", "bash", "zsh", "dash", "fish", "ksh", "python3", "python", "perl", "env", "timeout",
          "nohup", "script", "sandbox-exec", "caffeinate", "sudo", "su", "login", "tmux", "screen"}


def fail(message, code=1):
    print("ERROR: " + message, file=sys.stderr)
    sys.exit(code)


# ── time ──
def now():
    forced = os.environ.get("CLEARANCE_NOW")
    if forced:
        return parse_iso(forced)
    return datetime.now(timezone.utc).replace(microsecond=0)


def parse_iso(text):
    text = (text or "").strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        value = datetime.fromisoformat(text)
    except ValueError:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def age_text(since, at):
    if since is None:
        return "unknown"
    seconds = max(0, int((at - since).total_seconds()))
    if seconds < 60:
        return "%d s ago" % seconds
    if seconds < 3600:
        return "%d min ago" % (seconds // 60)
    return "%d h %d min ago" % (seconds // 3600, (seconds % 3600) // 60)


# ── the branch-patterns rule (skills/release/references/branch-patterns.md) ──
def pattern_regex(pattern):
    source, rest = "", pattern
    while rest:
        if rest.startswith("**"):
            source += ".+"; rest = rest[2:]
        elif rest.startswith("*"):
            source += "[^/]+"; rest = rest[1:]
        elif rest == "[-n]":
            source += "(-[0-9]+)?"; rest = ""
        elif re.match(r"^<[A-Z]{2}-[A-Z]{2}-[A-Z]{2}>", rest):
            source += "[0-9]{2}-[0-9]{2}-[0-9]{2}"; rest = rest[10:]
        else:
            source += re.escape(rest[0]); rest = rest[1:]
    return re.compile("^" + source + "$")


# ── configuration ──
def load_config():
    here = os.path.abspath(os.getcwd())
    while True:
        candidate = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(candidate):
            try:
                with open(candidate) as handle:
                    loaded = json.load(handle)
            except (OSError, ValueError) as error:
                fail("%s exists but cannot be read as JSON (%s) — fix it; the defaults would name a different ref" % (candidate, error))
            if not isinstance(loaded, dict):
                fail("%s is not a JSON object" % candidate)
            return loaded, here
        parent = os.path.dirname(here)
        if parent == here:
            return {}, None
        here = parent


def section(config, key):
    value = config.get(key)
    return value if isinstance(value, dict) else {}


CONFIG = RELEASE = CLEARANCE = TOWER = {}
CONFIG_DIR = None
STORE = None


def setting(env_name, config_value, default, kind=str):
    raw = os.environ.get(env_name)
    if raw is None or raw == "":
        raw = config_value
    if raw is None or raw == "":
        return default
    try:
        return kind(raw)
    except (TypeError, ValueError):
        return default


CACHE_DIR = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")


BUDGET_WARNINGS = []


def phase_budgets():
    """The defaults, then release.clearance.phaseBudgetMinutes, then CLEARANCE_PHASE_BUDGETS. A
    value that is not a positive number (0, null, "off") switches that phase's alarm off. A layer
    that is not an object is IGNORED with a warning, never an error: an alarm's settings must not
    stop a release from heartbeating or handing its clearance back."""
    budgets = dict(DEFAULT_PHASE_BUDGETS)
    layers = [("release.clearance.phaseBudgetMinutes", CLEARANCE.get("phaseBudgetMinutes"))]
    raw = os.environ.get("CLEARANCE_PHASE_BUDGETS")
    if raw:
        try:
            layers.append(("CLEARANCE_PHASE_BUDGETS", json.loads(raw)))
        except ValueError:
            layers.append(("CLEARANCE_PHASE_BUDGETS", raw))
    for name, layer in layers:
        if layer is None:
            continue
        if not isinstance(layer, dict):
            BUDGET_WARNINGS.append("%s ignored: it must be an object of phase → minutes" % name)
            continue
        for phase, minutes in layer.items():
            phase = str(phase)
            if minutes is None or (isinstance(minutes, (int, float)) and not isinstance(minutes, bool) and minutes <= 0):
                budgets.pop(phase, None)  # an explicit 0 or null switches the alarm off
            elif isinstance(minutes, (int, float)) and not isinstance(minutes, bool):
                budgets[phase] = int(minutes)
            else:
                BUDGET_WARNINGS.append("%s.%s ignored: %r is not a number of minutes" % (name, phase, minutes))
    return budgets


PHASE_BUDGETS = {}
STALE_MINUTES = DEFAULT_STALE_MINUTES
WAIT_MINUTES = DEFAULT_WAIT_MINUTES
POLL_SECONDS = 60
KEEPER_SECONDS = 60
PRODUCTION = "master"
RELEASE_SOURCE = "develop"
RELEASE_PATTERN = ""
HOTFIX_PATTERN = DEFAULT_HOTFIX_PATTERN


def init(provider):
    """Read the configuration and build the store. Not run for `identity`, which needs neither."""
    global CONFIG, CONFIG_DIR, RELEASE, CLEARANCE, TOWER, STORE, PHASE_BUDGETS
    global STALE_MINUTES, WAIT_MINUTES, POLL_SECONDS, KEEPER_SECONDS, PRODUCTION, RELEASE_SOURCE, RELEASE_PATTERN, HOTFIX_PATTERN
    CONFIG, CONFIG_DIR = load_config()
    RELEASE = section(CONFIG, "release")
    CLEARANCE = RELEASE.get("clearance") if isinstance(RELEASE.get("clearance"), dict) else {}
    TOWER = section(CONFIG, "releaseTower")
    STALE_MINUTES = setting("CLEARANCE_STALE_MINUTES", CLEARANCE.get("staleMinutes"), DEFAULT_STALE_MINUTES, int)
    WAIT_MINUTES = setting("CLEARANCE_WAIT_MINUTES", CLEARANCE.get("waitMinutes"), DEFAULT_WAIT_MINUTES, int)
    POLL_SECONDS = setting("CLEARANCE_POLL_SECONDS", None, 60, int)
    KEEPER_SECONDS = setting("CLEARANCE_KEEPER_SECONDS", None, max(60, STALE_MINUTES * 60 // 3), int)
    PRODUCTION = setting("CLEARANCE_PRODUCTION_BRANCH", RELEASE.get("productionBranch"), "master")
    RELEASE_SOURCE = RELEASE.get("releaseSource") or "develop"
    RELEASE_PATTERN = setting("CLEARANCE_RELEASE_PATTERN", RELEASE.get("releaseBranchPattern"), "")
    HOTFIX_PATTERN = setting("CLEARANCE_HOTFIX_PATTERN", TOWER.get("hotfixPattern"), DEFAULT_HOTFIX_PATTERN)
    STORE = GitHubStore() if provider == "github" else DevStrideStore()
    PHASE_BUDGETS = phase_budgets()


def record_path():
    """The local record, one file per repository: two repositories claimed under one account must
    not overwrite each other's (a keeper reads it to know it still serves its holder)."""
    return os.environ.get("CLEARANCE_RECORD") or os.path.join(
        CACHE_DIR, "devstride", "release-clearance", repo().replace("/", "__") + ".json")


def is_release_head(name):
    if RELEASE_PATTERN:
        return bool(pattern_regex(RELEASE_PATTERN).match(name))
    return name == RELEASE_SOURCE


def is_hotfix_head(name):
    return bool(pattern_regex(HOTFIX_PATTERN).match(name))


# ── tools ──
class ToolError(Exception):
    def __init__(self, text, rejected=False):
        super().__init__(text)
        self.text = text
        self.rejected = rejected


def run(args, body=None):
    proc = subprocess.run(args, input=body, capture_output=True, text=True)
    if proc.returncode == 0:
        return proc.stdout
    text = (proc.stderr or proc.stdout or "").strip()
    raise ToolError(text or "%s failed" % args[0])


def gh(args):
    return run(["gh", *args])


def gh_json(args):
    out = gh(args)
    try:
        return json.loads(out) if out.strip() else None
    except ValueError:
        raise ToolError("gh returned something that is not JSON: " + out[:200])


_repo = None


def repo():
    global _repo
    if _repo is None:
        _repo = os.environ.get("CLEARANCE_REPO") or gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()
        if not re.match(r"^[^/\s]+/[^/\s]+$", _repo):
            fail("could not determine the repository (gh repo view); is this a GitHub checkout?")
    return _repo


def gh_user():
    try:
        return gh(["api", "user", "--jq", ".login"]).strip() or "unknown"
    except ToolError:
        return "unknown"


# ── identity (one identity means one thing across the clearance commands) ──
# CLEARANCE_HOLDER_TOKEN names the holder; DEVSTRIDE_LEASE_TOKEN is its older name, still read when
# the new one is unset, and the new name wins when both are set.
def whoami():
    """The holder, told to the store (the DevStride store sends it with every call)."""
    me, generated = holder()
    STORE.identify(me)
    return me, generated


def holder():
    name = "CLEARANCE_HOLDER_TOKEN"
    token = os.environ.get(name)
    if not token:
        name, token = "DEVSTRIDE_LEASE_TOKEN", os.environ.get("DEVSTRIDE_LEASE_TOKEN")
    if token:
        if re.search(r"[|\s]", token):
            fail("%s cannot contain | or whitespace" % name)
        return token, False
    ids = []
    if os.environ.get("CODEX_THREAD_ID"):
        ids.append("codex:" + os.environ["CODEX_THREAD_ID"])
    if os.environ.get("CLAUDE_CODE_SESSION_ID"):
        ids.append("claude:" + os.environ["CLAUDE_CODE_SESSION_ID"])
    if ids:
        return "+".join(ids), False
    return "token:" + secrets.token_hex(12), True


# ── the stores: where the one record lives, and how it moves atomically ──
# A store speaks in whole records. read() returns the record (with an opaque `_version`) or None.
# create / renew / take_over / adopt / delete each move it only if it still is what the caller
# read, and raise ToolError(rejected=True) when someone else got there first: the verbs above
# the store never see a ref, a push or a tool call. `rid(me)` is the holder as the record names
# it, `shown(rid)` what a line may print of it, `holds(record, me)` the comparison.
class Store:
    def rid(self, me):
        return me

    def shown(self, rid):
        return rid

    def as_rid(self, holder):
        """A holder read back from a local file, as the store names it."""
        return holder

    def identify(self, me):
        pass

    def holds(self, record, me):
        return bool(record) and record.get("holder") == self.rid(me)

    def refusal(self, text):
        return ToolError(text.splitlines()[0] if text else "the store refused the change")

    def beat(self, record):
        """The keeper's liveness stamp. A compare-and-swap store re-writes the record it just read."""
        self.renew(record, record)


def unreadable(record):
    return bool(record) and record.get("_invalid") is True


def lost(text="someone else changed the clearance first"):
    return ToolError(text, rejected=True)


# ── the GitHub store: a custom git ref pointing at a tag object, moved by compare-and-swap ──
class GitHubStore(Store):
    def __init__(self):
        self.ref = setting("CLEARANCE_REF", CLEARANCE.get("ref"), DEFAULT_REF)
        if not self.ref.startswith("refs/") or self.ref.count("/") < 2:
            fail("release.clearance.ref must be a fully qualified ref such as refs/clearance/release")
        self.remote = setting("CLEARANCE_REMOTE", None, "origin")

    @property
    def name(self):
        return self.ref

    def remote_sha(self):
        """The sha the remote holds for the ref, or None when it does not exist. Raises when the
        remote cannot be asked (not signed in, no network, no such remote): never read as clear."""
        proc = subprocess.run(["git", "ls-remote", "--exit-code", self.remote, self.ref], capture_output=True, text=True)
        if proc.returncode == 2:
            return None
        if proc.returncode != 0:
            raise ToolError((proc.stderr or proc.stdout).strip() or "git ls-remote failed")
        line = proc.stdout.strip().splitlines()
        return line[0].split()[0] if line else None

    version = remote_sha

    def read(self):
        """The clearance record (with its object sha as `_version`), or None when the ref is absent."""
        sha = self.remote_sha()
        if sha is None:
            return None
        # Bring the object here (fetching the ref is always allowed; a bare sha may not be).
        have = subprocess.run(["git", "cat-file", "-e", sha], capture_output=True).returncode == 0
        if not have:
            run(["git", "fetch", "-q", self.remote, self.ref])
            if subprocess.run(["git", "cat-file", "-e", sha], capture_output=True).returncode != 0:
                # The ref moved between the two calls: read what we fetched instead.
                sha = run(["git", "rev-parse", "FETCH_HEAD"]).strip()
        raw = run(["git", "cat-file", "-p", sha])
        message = raw.split("\n\n", 1)[1] if "\n\n" in raw else ""
        try:
            record = json.loads(message)
        except ValueError:
            record = None
        if not isinstance(record, dict) or not isinstance(record.get("holder"), str) or not record["holder"] \
                or parse_iso(record.get("takenAt")) is None:
            # Something that is not a clearance record holds the ref. Nobody may take it over
            # silently: it is reported, and only the owner's `release --force` clears it.
            record = {"_invalid": True}
        record["_version"] = sha
        return record

    def write_tag(self, record):
        """A new tag object carrying the record, in the local object store; returns its sha. It
        points at a blob of the same text, written here too, so the push never needs a commit this
        checkout may not have fetched (the production head right after a merge on GitHub, say)."""
        text = json.dumps(clean_record(record), sort_keys=True)
        blob = run(["git", "hash-object", "-w", "--stdin"], text + "\n").strip()
        body = "object %s\ntype blob\ntag release-clearance\ntagger release-clearance <release-clearance@devstride.plugin> %d +0000\n\n%s\n" % (
            blob, int(time.time()), text)
        return run(["git", "hash-object", "-t", "tag", "-w", "--stdin"], body).strip()

    def push_ref(self, new_sha, expected):
        """Move the ref to new_sha (or delete it when new_sha is None) only if the remote still has
        `expected` ('' = absent). Raises ToolError(rejected=True) when the lease failed."""
        spec = ("%s:%s" % (new_sha, self.ref)) if new_sha else (":" + self.ref)
        # --no-verify: the ref carries no code, and a repository's pre-push hook (type-checks, a
        # generator that amends HEAD) is for its branches — not for every heartbeat and keeper tick.
        proc = subprocess.run(["git", "push", "-q", "--no-verify", self.remote, spec, "--force-with-lease=%s:%s" % (self.ref, expected or "")],
                              capture_output=True, text=True)
        if proc.returncode == 0:
            return
        text = (proc.stderr or proc.stdout or "").strip()
        if "rejected" in text or "stale info" in text or "declined" in text:
            raise ToolError(text, rejected=True)
        raise self.refusal(text)

    def refusal(self, text):
        """The error for a push the server refused: its own words first, and the ruleset finding
        when they point at one."""
        first = text.splitlines()[0] if text else "git push failed"
        if "403" in text or "protected" in text.lower() or "rule" in text.lower():
            return ToolError("%s — pushing %s was refused; a repository ruleset that restricts ref creation blocks "
                             "the clearance ref (clearance.md)" % (first, self.ref))
        return ToolError(first)

    def create(self, record):
        self.push_ref(self.write_tag(record), None)

    def renew(self, record, expected):
        self.push_ref(self.write_tag(record), expected["_version"])

    take_over = adopt = renew

    def delete(self, expected, force=False):
        self.push_ref(None, expected["_version"])


# ── the DevStride store: one claim, kind release-tower, keyed by the repository ──
CLAIM_KIND = "release-tower"
BASE_URL_RULE = re.compile(r"^https://api(-[a-z0-9-]+)?\.devstride\.(com|dev)\Z")
CREDENTIAL_NAMES = ("DEVSTRIDE_API_KEY", "DEVSTRIDE_API_SECRET", "DEVSTRIDE_ORG_ID", "DEVSTRIDE_ORG_SLUG", "DEVSTRIDE_BASE_URL")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class DevStrideStore(Store):
    def __init__(self):
        self.me = None
        self.secrets = []
        self._creds = None

    @property
    def name(self):
        return "DevStride claim %s/%s" % (CLAIM_KIND, repo())

    def rid(self, me):
        return hashlib.sha256(me.encode()).hexdigest()

    def shown(self, rid):
        return (rid or "?")[:12]

    def as_rid(self, holder):
        # An owed file written before holders were stored as digests names the raw holder.
        return holder if re.match(r"^[0-9a-f]{64}\Z", holder) else self.rid(holder)

    def identify(self, me):
        self.me = me
        self.secrets.append(me)

    # credentials: the environment first, then the file release.clearance.credentialsFile names
    def credentials(self):
        if self._creds is not None:
            return self._creds
        values = {n: os.environ.get(n) or "" for n in CREDENTIAL_NAMES}
        path = CLEARANCE.get("credentialsFile")
        if isinstance(path, str) and path and not all(values.values()):
            path = os.path.expanduser(path)
            if not os.path.isabs(path):
                path = os.path.join(CONFIG_DIR or os.getcwd(), path)
            try:
                info = os.lstat(path)
            except OSError:
                info = None
            if info is not None:
                if not os.path.isfile(path) or os.path.islink(path) or info.st_uid != os.getuid():
                    raise ToolError("credentials file %s must be a regular file you own, not a link" % path)
                if info.st_mode & 0o077:
                    raise ToolError("credentials file %s is readable by others — chmod 600 it" % path)
                try:
                    with open(path) as handle:
                        lines = handle.read().splitlines()
                except OSError:
                    raise ToolError("credentials file %s cannot be read" % path)
                for line in lines:
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
        missing = [n for n in CREDENTIAL_NAMES[:3] if not values[n]]
        if missing:
            raise ToolError("DevStride credentials missing (%s) — set them in the environment, or in the file "
                            "release.clearance.credentialsFile names (mode 600)" % ", ".join(missing))
        base = values["DEVSTRIDE_BASE_URL"] or "https://api.devstride.com"
        test = os.environ.get("CLEARANCE_DEVSTRIDE_TEST_URL")
        if test:
            if not re.match(r"^http://(127\.0\.0\.1|localhost):[0-9]+$", test):
                raise ToolError("CLEARANCE_DEVSTRIDE_TEST_URL must be http://127.0.0.1:<port>")
            base = test
        elif not BASE_URL_RULE.match(base):
            raise ToolError("DEVSTRIDE_BASE_URL must be https://api.devstride.com (or an api-<stage>.devstride.com/.dev host)")
        self.secrets += [values["DEVSTRIDE_API_KEY"], values["DEVSTRIDE_API_SECRET"]]
        self._creds = dict(values, base=base, test=bool(test))
        return self._creds

    def scrub(self, text):
        first = (text or "").strip().splitlines()[0] if (text or "").strip() else ""
        for secret in self.secrets:
            if secret:
                first = first.replace(secret, "***")
        return first[:300]

    def absent(self, headers):
        version = ""
        for header in ("X-DevStride-Version", "X-App-Version"):
            version = (headers.get(header) if headers else "") or version
        return ToolError("this DevStride server has no claim tools (claim_work); it needs a release with agent claims "
                         "(server version %s)" % (self.scrub(version) or "unknown"))

    def forbidden(self, detail):
        return ToolError("DevStride refused the request (%s) — the key's user needs the MANAGE_AGENT_CLAIMS permission, "
                         "and the key, secret and organization must belong together" % detail)

    def classify(self, text, headers):
        if "Unknown tool:" in (text or ""):
            return self.absent(headers)
        if "MANAGE_AGENT_CLAIMS" in (text or ""):
            return self.forbidden(self.scrub(text))
        return ToolError(self.scrub(text) or "DevStride returned an error")

    def call(self, tool, arguments):
        cred = self.credentials()
        headers = {"X-DevStride-Api-Key": cred["DEVSTRIDE_API_KEY"], "X-DevStride-Api-Secret": cred["DEVSTRIDE_API_SECRET"],
                   "X-DevStride-Organization-Id": cred["DEVSTRIDE_ORG_ID"], "Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream"}
        if cred["DEVSTRIDE_ORG_SLUG"]:
            headers["X-DevStride-Organization-Slug"] = cred["DEVSTRIDE_ORG_SLUG"]
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}).encode()
        handlers = [NoRedirect()] + ([urllib.request.ProxyHandler({})] if cred["test"] else [])
        opener = urllib.request.build_opener(*handlers)
        reply, answer_headers = None, None
        for attempt in (1, 2):
            request = urllib.request.Request(cred["base"] + "/mcp", data=body, headers=headers, method="POST")
            try:
                with opener.open(request, timeout=30) as response:
                    reply, answer_headers = response.read().decode("utf-8", "replace"), response.headers
                break
            except urllib.error.HTTPError as error:
                if error.code in (401, 403):
                    raise self.forbidden("HTTP %d" % error.code)
                if error.code >= 500 and attempt == 1:
                    continue
                raise ToolError("DevStride answered HTTP %d" % error.code)
            except (urllib.error.URLError, OSError, http.client.HTTPException):
                if attempt == 1:
                    continue
                raise ToolError("DevStride could not be reached")
            except ValueError:
                raise ToolError("the DevStride address is not a valid URL")
        return self.unwrap(reply, answer_headers)

    def unwrap(self, reply, headers):
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
            raise ToolError("DevStride returned something that is not a JSON-RPC answer")
        if isinstance(message.get("error"), dict):
            raise self.classify(str(message["error"].get("message") or ""), headers)
        result = message.get("result")
        content = result.get("content") if isinstance(result, dict) else None
        text = content[0].get("text") if isinstance(content, list) and content and isinstance(content[0], dict) else None
        if not isinstance(text, str):
            raise ToolError("DevStride returned an answer with no content")
        if result.get("isError"):
            raise self.classify(text, headers)
        try:
            data = json.loads(text)
        except ValueError:
            raise ToolError("DevStride returned a claim answer that is not JSON")
        return data["data"] if isinstance(data, dict) and "data" in data else data

    # records
    def version_of(self, row):
        return "%s|%s|%s" % (row.get("holderDigest"), row.get("heartbeatAt"), row.get("expiresAt"))

    def read(self):
        row = self.call("get_claim", {"kind": CLAIM_KIND, "key": repo()})
        if isinstance(row, dict) and "kind" not in row and "claim" in row:
            row = row["claim"]
        if not isinstance(row, dict) or row.get("releasedAt"):
            return None
        digest, payload = row.get("holderDigest"), row.get("payload")
        if not isinstance(payload, dict) or not isinstance(digest, str) or not digest or parse_iso(payload.get("takenAt")) is None:
            return {"_invalid": True, "_version": self.version_of(row)}
        record = dict(payload, holder=digest, _version=self.version_of(row))
        if parse_iso(row.get("heartbeatAt")) is not None:
            record["heartbeatAt"] = row["heartbeatAt"]  # the server's stamp: a keeper beat moves only that
        expires = parse_iso(row.get("expiresAt"))
        if expires is not None and now() > expires:
            # The server's clock lapsed the claim: that is a stale record (its keeper is dead).
            lapsed = expires - timedelta(minutes=STALE_MINUTES)
            beat = parse_iso(record.get("heartbeatAt") or record.get("takenAt"))
            record["heartbeatAt"] = iso(min(beat, lapsed) if beat else lapsed)
        return record

    def version(self):
        record = self.read()
        return record["_version"] if record else None

    def claim(self, record, takeover=None):
        arguments = {"kind": CLAIM_KIND, "key": repo(), "purpose": record.get("purpose") or "release", "phase": record.get("phase"),
                     "payload": clean_record(record), "expiryMinutes": STALE_MINUTES, "holder": self.me, "machine": claim_record.machine_name(), **session_name()}
        if takeover:
            arguments["takeover"] = {"expectedHolderDigest": takeover}
        if not (self.call("claim_work", arguments) or {}).get("won"):
            raise lost()

    def refuse_unless(self, answer):
        if not isinstance(answer, dict) or answer.get("outcome") == "NOT_HOLDER":
            raise lost()

    def create(self, record):
        self.claim(record)

    def take_over(self, record, expected):
        self.claim(record, takeover=expected["holder"])

    def renew(self, record, expected):
        # The server renews its holder's lapsed claim too, unless someone took it over (NOT_HOLDER):
        # never claim_work here, which would win afresh a claim released a moment ago.
        self.refuse_unless(self.call("heartbeat_claim", {
            "kind": CLAIM_KIND, "key": repo(), "phase": record.get("phase"), "payload": clean_record(record),
            "expiryMinutes": STALE_MINUTES, "holder": self.me}))

    def beat(self, record):
        # Liveness only: no phase or payload, so a keeper tick never undoes the owner's phase change.
        self.refuse_unless(self.call("heartbeat_claim", {
            "kind": CLAIM_KIND, "key": repo(), "expiryMinutes": STALE_MINUTES, "holder": self.me}))

    def adopt(self, record, expected):
        self.refuse_unless(self.call("adopt_claim", {
            "kind": CLAIM_KIND, "key": repo(), "expectedHolderDigest": expected["holder"], "phase": record.get("phase"),
            "payload": clean_record(record), "holder": self.me, "machine": claim_record.machine_name(),
            **session_name()}))

    def delete(self, expected, force=False):
        arguments = {"kind": CLAIM_KIND, "key": repo(), "outcome": "released", "holder": self.me}
        if force:
            arguments["force"] = True
        answer = self.call("release_claim", arguments)
        self.refuse_unless(answer)
        if not answer.get("released"):
            raise lost()


def session_name():
    """The claim's sessionName argument, only when this session has a name."""
    name = claim_record.session_name(os.environ)
    return {"sessionName": name} if name else {}


def clean_record(record):
    return {k: v for k, v in record.items() if not k.startswith("_")}


def lost_race(error, expected, stuck):
    """A rejected change is a lost race only when the record MOVED. The same record after three
    rejections is the store refusing the change (a hook, a ruleset): raise it instead of retrying
    forever. Returns the new stuck count."""
    if STORE.version() != expected:
        return 0
    if stuck + 1 >= 3:
        raise STORE.refusal(error.text)
    return stuck + 1


def is_stale(record, at):
    beat = parse_iso(record.get("heartbeatAt") or record.get("takenAt"))
    return beat is None or (at - beat).total_seconds() > STALE_MINUTES * 60


def phase_minutes(record, at):
    """Whole minutes the record has been in its current phase, or None when it does not say (a
    record written before phaseStartedAt existed)."""
    start = parse_iso(record.get("phaseStartedAt"))
    if start is None:
        return None
    return max(0, int((at - start).total_seconds()) // 60)


def is_stuck(record, at):
    """Alive is not moving: the current phase has a budget and has run past it."""
    if not record or unreadable(record) or is_stale(record, at):
        return False  # a stale clearance is not alive, so it cannot be stuck
    budget = PHASE_BUDGETS.get(record.get("phase") or "")
    minutes = phase_minutes(record, at)
    return bool(budget) and minutes is not None and minutes > budget


def pr_state(number):
    try:
        return gh(["pr", "view", str(number), "--repo", repo(), "--json", "state", "--jq", ".state"]).strip().upper()
    except ToolError:
        return "UNKNOWN"


# ── the local record (what a hook reads to answer "does THIS session hold clearance?") ──
def owed_path():
    """The close-out-owed file beside the local record: the record itself means "this session holds
    clearance" to a hook, so work owed after the hand-back cannot live in it."""
    forced = os.environ.get("CLEARANCE_OWED_RECORD")
    if forced:
        return forced
    base = record_path()
    return (base[:-5] if base.endswith(".json") else base) + ".owed.json"


def read_owed():
    """Entries for this repository, oldest first; never raises (status must not fail on it, and
    --short must keep working with gh down, so the repository is asked for only when some owed
    file exists at all)."""
    if not os.environ.get("CLEARANCE_OWED_RECORD") and not os.environ.get("CLEARANCE_RECORD"):
        directory = os.path.join(CACHE_DIR, "devstride", "release-clearance")
        try:
            if not any(name.endswith(".owed.json") for name in os.listdir(directory)):
                return []
        except OSError:
            return []
    try:
        path = owed_path()
    except (ToolError, SystemExit):
        return []
    try:
        with open(path) as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return []
    entries = value.get("entries") if isinstance(value, dict) else None
    if not isinstance(entries, list):
        return []
    try:
        here = repo()
    except (ToolError, SystemExit):
        here = None
    kept = [e for e in entries if isinstance(e, dict) and e.get("repo") in (None, here)
            and isinstance(e.get("owed"), list) and e["owed"]]
    for entry in kept:
        if isinstance(entry.get("holder"), str) and entry["holder"]:
            entry["holder"] = STORE.as_rid(entry["holder"])
    return kept


def write_owed(entries):
    directory = os.path.dirname(owed_path())
    if directory:
        os.makedirs(directory, exist_ok=True)
    if not entries:
        try:
            os.remove(owed_path())
        except OSError:
            pass
        return
    tmp = "%s.%d.tmp" % (owed_path(), os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump({"entries": entries}, handle)
    os.replace(tmp, owed_path())


def owed_line(entry, at):
    where = entry.get("release") or "release"
    if entry.get("pr"):
        where += " #%s" % entry["pr"]
    return "%s — %s (handed back %s by %s on %s, session %s)" % (
        where, ", ".join(str(i) for i in entry["owed"]), age_text(parse_iso(entry.get("releasedAt")), at),
        entry.get("user") or "?", entry.get("machine") or "?", STORE.shown(entry["holder"]) if entry.get("holder") else "?")


def read_local():
    try:
        with open(record_path()) as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def write_local(record, me, keeper_pid=None):
    directory = os.path.dirname(record_path())
    os.makedirs(directory, exist_ok=True)
    current = read_local() or {}
    payload = {
        "repo": repo(), "holder": me, "user": record.get("user"),
        "machine": record.get("machine"), "branch": record.get("branch"), "pr": record.get("pr"),
        "takenAt": record.get("takenAt"),
        "keeperPid": keeper_pid if keeper_pid is not None else (current.get("keeperPid") if current.get("repo") == repo() else None),
    }
    tmp = record_path() + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle)
    os.chmod(tmp, 0o600)
    os.replace(tmp, record_path())


def remove_local(me=None):
    """Remove this repository's record when it names `me` (None: whoever's it is — the owner's
    --force, or a record with no holder), stopping its keeper; another holder's stays."""
    current = read_local()
    if current is None or current.get("repo") not in (None, repo()):
        return
    if me is not None and current.get("holder") not in (None, me):
        return
    stop_keeper(current)
    try:
        os.remove(record_path())
    except OSError:
        pass


def lost_holding(me):
    """This session no longer holds the clearance: a local record naming it is now wrong."""
    remove_local(me)


# ── the keeper ──
def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def owner_pid():
    """The agent process that is running this command: the first ancestor that is not a shell
    or a wrapper. Its death is what makes a clearance go stale."""
    forced = os.environ.get("CLEARANCE_OWNER_PID")
    if forced:
        return int(forced) if forced.isdigit() else None
    pid = os.getppid()
    for _ in range(12):
        if pid <= 1:
            return None
        try:
            out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
        except OSError:
            return None
        if len(out) < 2:
            return None
        parent, comm = out[0], os.path.basename(out[1])
        if comm not in SHELLS:
            return pid
        pid = int(parent) if parent.isdigit() else 0
    return None


def start_keeper(me):
    """Detach a keeper for this holder. Returns its pid, or None (and says why) when none runs."""
    if os.environ.get("CLEARANCE_NO_KEEPER"):
        return None
    owner = owner_pid()
    if owner is None:
        progress("no keeper: the owning process could not be found — run heartbeat yourself at least every %d minutes" % STALE_MINUTES)
        return None
    # The repository is handed over resolved: a keeper that asked gh at its first tick would die
    # for good on one transient failure, and the clearance would go stale during a long phase.
    env = dict(os.environ, CLEARANCE_KEEPER_HOLDER=me, CLEARANCE_KEEPER_OWNER=str(owner), CLEARANCE_REPO=repo())
    env.pop("CLEARANCE_NOW", None)
    proc = subprocess.Popen(["bash", os.environ["CLEARANCE_SELF"], "keeper"], env=env, cwd=os.getcwd(),
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    return proc.pid


def stop_keeper(local):
    pid = (local or {}).get("keeperPid")
    if isinstance(pid, int) and pid > 1 and alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass


def cmd_keeper(_args):
    me = os.environ.get("CLEARANCE_KEEPER_HOLDER")
    owner = int(os.environ.get("CLEARANCE_KEEPER_OWNER") or "0")
    if not me or owner <= 1:
        return 1
    STORE.identify(me)
    while True:
        time.sleep(KEEPER_SECONDS)
        if not alive(owner):
            return 0
        local = read_local()
        if not local or local.get("repo") != repo() or local.get("holder") != me:
            return 0
        try:
            record = STORE.read()
            if record is None or unreadable(record) or not STORE.holds(record, me):
                return 0
            record["heartbeatAt"] = iso(now())
            STORE.beat(record)
        except ToolError:
            continue  # a failed stamp is retried next tick; the owner's death still ends it


# ── output lines ──
def describe(record, at):
    if unreadable(record):
        return "UNREADABLE record at %s (not a clearance record) — the owner clears it with release --force" % record["_version"][:12]
    beat = parse_iso(record.get("heartbeatAt") or record.get("takenAt"))
    line = "held by %s on %s since %s, phase %s, heartbeat %s" % (
        record.get("user") or "?", record.get("machine") or "?", record.get("takenAt") or "?",
        record.get("phase") or "?", age_text(beat, at))
    where = []
    if record.get("branch"):
        where.append(record["branch"])
    if record.get("pr"):
        where.append("#%s" % record["pr"])
    if where:
        line += " — " + " ".join(where)
    if is_stale(record, at):
        line += " — STALE"
    if is_stuck(record, at):
        line += " — STUCK in %s for %d min (budget %d min), session %s on %s" % (
            record.get("phase"), phase_minutes(record, at), PHASE_BUDGETS[record.get("phase")],
            STORE.shown(record.get("holder")), record.get("machine") or "?")
    return line


def option(args, name):
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            fail("%s needs a value" % name, 1)
        return args[i + 1]
    return None


def pr_number(value):
    text = str(value).lstrip("#").strip()
    return int(text) if text.isdigit() else text


# ── commands ──
def progress(line):
    print(line, file=sys.stderr, flush=True)


def renew(record, me, at):
    """Re-stamp a record this session holds (a claim or adoption by the holder itself). Returns the
    rejecting error when the lease failed, None when the stamp landed."""
    record["heartbeatAt"] = iso(at)
    try:
        STORE.renew(record, record)
    except ToolError as error:
        if not error.rejected:
            raise
        return error
    return None


def keeper_for(me):
    local = read_local() or {}
    keeper = local.get("keeperPid") if local.get("repo") == repo() else None
    return keeper if isinstance(keeper, int) and alive(keeper) else start_keeper(me)


def cmd_claim(args):
    wait = "--wait" in args
    stop_on_stuck = wait and "--ignore-stuck" not in args
    purpose = option(args, "--purpose") or "release"
    me, print_token = whoami()
    if print_token:
        progress("holder token %s — export it as CLEARANCE_HOLDER_TOKEN for heartbeat and release" % me)
    user = None
    deadline = time.monotonic() + WAIT_MINUTES * 60
    stuck = 0
    while True:
        at = now()
        try:
            current = STORE.read()
        except ToolError as error:
            # A wait of hours must not end on one failed read; outside a wait it is the error.
            if not wait or time.monotonic() >= deadline:
                raise
            progress("UNKNOWN (%s) — polling again" % (error.text.splitlines()[0] if error.text else "the ref could not be read"))
            time.sleep(POLL_SECONDS)
            continue
        if unreadable(current):
            print("ERROR: " + describe(current, at))
            return 1
        if user is None:
            user = gh_user()
        if current is None or (is_stale(current, at) and not STORE.holds(current, me)):
            if current is not None:
                number = current.get("pr")
                state = pr_state(number) if number else "NONE"
                if state == "UNKNOWN":
                    print("ERROR: the state of pull request #%s could not be read, so the stale clearance (%s) "
                          "cannot be judged" % (number, describe(current, at)))
                    return 1
                if state in ("OPEN", "MERGED"):
                    why = "still open" if state == "OPEN" else "merged but the release was never closed out"
                    print("STALE %s — pull request #%s %s — adopt or wait" % (describe(current, at), number, why))
                    return 3
            record = {
                "v": RECORD_VERSION, "repo": repo(), "holder": STORE.rid(me), "user": user, "machine": claim_record.machine_name(),
                "purpose": purpose, "phase": "claimed", "branch": None, "pr": None,
                "takenAt": iso(at), "heartbeatAt": iso(at), "phaseStartedAt": iso(at),
            }
            try:
                # Absent → the store expects nothing there; stale → it expects exactly the stale
                # record. Either way the store decides, and a loser reads who won.
                if current is None:
                    STORE.create(record)
                else:
                    STORE.take_over(record, current)
            except ToolError as error:
                if not error.rejected:
                    raise
                stuck = lost_race(error, None if current is None else current["_version"], stuck)
                continue
            if current is not None:
                progress("stale clearance taken over (%s; pull request %s)" % (
                    describe(current, at), ("#%s %s" % (number, state.lower())) if number else "never opened"))
            write_local(record, me, start_keeper(me))
            print("CLEARED %s %s" % (STORE.shown(record["holder"]), record["takenAt"]))
            return 0
        if STORE.holds(current, me):
            rejected = renew(current, me, at)
            if rejected is not None:
                stuck = lost_race(rejected, current["_version"], stuck)
                continue  # moved under us: read again
            write_local(current, me, keeper_for(me))
            print("CLEARED %s %s (already held by this session; heartbeat renewed)" % (STORE.shown(current["holder"]), current.get("takenAt")))
            return 0
        line = "BUSY " + describe(current, at)
        if stop_on_stuck and is_stuck(current, at):
            # Alive but not moving: end the wait once so the waiting session can tell the owner;
            # it waits again with --ignore-stuck. Nothing is taken over.
            print("STUCK " + describe(current, at))
            return 5
        if not wait or time.monotonic() >= deadline:
            print(line)
            return 2
        progress(line)
        time.sleep(POLL_SECONDS)


def list_prs(state, since=None):
    """Pull requests into production in `state`; with `since` (an ISO time), only those merged on
    or after its date, so a production branch with years of merges never fills the page."""
    fields = "number,headRefName,isDraft,createdAt,mergedAt"
    args = ["pr", "list", "--repo", repo(), "--base", PRODUCTION, "--state", state, "--limit", str(PR_LIMIT), "--json", fields]
    if since:
        args += ["--search", "merged:>=" + since[:10]]
    try:
        rows = gh_json(args) or []
    except ToolError:
        return None
    return [row for row in rows if isinstance(row, dict)]


def derive(record, at):
    """What GitHub says about release pull requests and hotfix landings — never recorded."""
    out = {"onFinal": None, "waiting": [], "hotfixesLanded": [], "derived": True}
    open_prs = list_prs("open")
    if open_prs is None or len(open_prs) >= PR_LIMIT:
        out["derived"] = False
        return out
    releases = sorted((p for p in open_prs if is_release_head(p.get("headRefName", ""))), key=lambda p: p["number"])
    if releases:
        first = releases[0]
        out["onFinal"] = {"number": first["number"], "head": first["headRefName"], "draft": bool(first.get("isDraft"))}
        out["waiting"] = [{"number": p["number"], "head": p["headRefName"], "draft": bool(p.get("isDraft"))} for p in releases[1:]]
    if record:
        since = parse_iso(record.get("takenAt"))
        merged = list_prs("merged", since=record.get("takenAt"))
        if merged is None or len(merged) >= PR_LIMIT:
            out["derived"] = False
        else:
            for p in merged:
                when = parse_iso(p.get("mergedAt"))
                if is_hotfix_head(p.get("headRefName", "")) and when and since and when >= since:
                    out["hotfixesLanded"].append({"number": p["number"], "head": p["headRefName"], "mergedAt": p.get("mergedAt")})
    return out


def cmd_status(args):
    at = now()
    try:
        record = STORE.read()
    except ToolError as error:
        first = error.text.splitlines()[0] if error.text else "unreadable"
        if "--json" in args:
            print(json.dumps({"state": "unknown", "error": first}))
        elif "--short" not in args:
            print("UNKNOWN (%s)" % first)
        return 1
    if unreadable(record):
        if "--json" in args:
            print(json.dumps({"state": "unknown", "error": describe(record, at), "ref": STORE.name, "sha": record["_version"]}))
        elif "--short" not in args:
            print("UNKNOWN (%s)" % describe(record, at))
        return 1
    stale = bool(record) and is_stale(record, at)
    stuck = is_stuck(record, at)
    owed = read_owed()
    if "--short" in args:
        if record:
            what = record.get("branch") or record.get("purpose") or "release"
            print("%s · %s · %s%s%s" % (what, record.get("user") or "?", record.get("phase") or "?",
                                        " · STALE" if stale else "", " · STUCK" if stuck else ""))
        elif owed:
            latest = owed[-1]
            print("close-out owed · %s · %s" % (latest.get("release") or "release", ", ".join(str(i) for i in latest["owed"])))
        return 0
    facts = derive(record, at)
    if "--json" in args:
        clean = {k: v for k, v in (record or {}).items() if not k.startswith("_")} if record else None
        print(json.dumps({
            "state": "held" if record else "clear", "stale": stale, "staleMinutes": STALE_MINUTES,
            "stuck": stuck, "phaseMinutes": phase_minutes(record, at) if record else None,
            "phaseBudgetMinutes": PHASE_BUDGETS, "closeOutOwed": owed, "warnings": BUDGET_WARNINGS,
            "now": iso(at), "ref": STORE.name, "repo": repo(), "productionBranch": PRODUCTION, "record": clean, **facts,
        }, sort_keys=True))
        return 0
    print("Clearance: " + describe(record, at) if record else "CLEAR")
    if facts["onFinal"]:
        f = facts["onFinal"]
        print("On final: #%s %s%s" % (f["number"], f["head"], " (draft)" if f["draft"] else ""))
    for w in facts["waiting"]:
        print("Waiting: #%s %s%s" % (w["number"], w["head"], " (draft)" if w["draft"] else ""))
    for h in facts["hotfixesLanded"]:
        print("Hotfix landed: #%s %s %s" % (h["number"], h["head"], h["mergedAt"]))
    if not facts["derived"]:
        print("(pull requests into %s could not be listed)" % PRODUCTION)
    for entry in owed:
        print("Close-out owed: " + owed_line(entry, at))
    for warning in BUDGET_WARNINGS:
        print("(%s)" % warning)
    return 0


def cmd_heartbeat(args):
    if not args or args[0].startswith("--"):
        fail("heartbeat needs a phase as its first argument", 1)
    phase = args[0]
    me, _ = whoami()
    at = now()
    record = STORE.read()
    if record is None:
        print("NOT HOLDER: no clearance is held (claim first)")
        lost_holding(me)
        return 4
    if unreadable(record) or not STORE.holds(record, me):
        print("NOT HOLDER: " + describe(record, at))
        lost_holding(me)
        return 4
    if record.get("phase") != phase or not record.get("phaseStartedAt"):
        record["phaseStartedAt"] = iso(at)
    record["phase"] = phase
    branch = option(args, "--branch")
    number = option(args, "--pr")
    if branch:
        record["branch"] = branch
    if number:
        record["pr"] = pr_number(number)
    record["heartbeatAt"] = iso(at)
    stuck = 0
    while True:
        try:
            STORE.renew(record, record)
            break
        except ToolError as error:
            if not error.rejected:
                raise
            current = STORE.read()
            if current is None or unreadable(current) or not STORE.holds(current, me):
                print("NOT HOLDER: " + (describe(current, at) if current else "the clearance was released under this session"))
                lost_holding(me)
                return 4
            # This session's own keeper stamped the ref between the read and the push: carry on
            # from the object it wrote. NOT HOLDER is for a record naming someone else.
            stuck = lost_race(error, record["_version"], stuck)
            record["_version"] = current["_version"]
    write_local(record, me)
    print("HEARTBEAT %s %s" % (phase, record["heartbeatAt"]))
    return 0


def options(args, name):
    values = []
    for i, arg in enumerate(args):
        if arg == name:
            if i + 1 >= len(args) or args[i + 1].startswith("--"):
                fail("%s needs a value" % name, 1)
            values.append(args[i + 1])
    return values


def record_owed(items, record, me, at):
    """Append (or replace) this release's close-out-owed entry. Prints the second line."""
    if not items:
        return
    local = read_local() or {}
    source = record if record and not unreadable(record) else local
    name = source.get("branch") or source.get("purpose") or "release"
    # The holder as the store names it (the DevStride store: its digest), never the raw holder:
    # status --json prints these entries.
    entry = {"repo": repo(), "release": name, "pr": source.get("pr"), "holder": STORE.rid(me),
             "user": source.get("user") if source.get("holder") in (me, STORE.rid(me)) else gh_user(),
             "machine": claim_record.machine_name(), "releasedAt": iso(at), "owed": list(dict.fromkeys(items))}
    # One entry per release: the name repeats when no release branch is cut ("release"), so the
    # pull request tells two releases apart.
    entries = [e for e in read_owed() if (e.get("release"), e.get("pr")) != (name, entry["pr"])]
    entries.append(entry)
    write_owed(entries)
    print("Close-out owed: " + ", ".join(entry["owed"]))


def cmd_release(args):
    force = "--force" in args
    owed_items = options(args, "--owed")
    me, _ = whoami()
    at = now()
    record = STORE.read()
    if record is None:
        print("CLEAR (nothing to release)")
        record_owed(owed_items, None, me, at)
        remove_local(None if force else me)
        return 0
    if (unreadable(record) or not STORE.holds(record, me)) and not force:
        print("NOT HOLDER: " + describe(record, at) + " — the holder releases it, or the owner runs release --force")
        lost_holding(me)
        return 4
    if force:
        progress("forcing release of a clearance " + describe(record, at))
    stuck = 0
    while True:
        try:
            STORE.delete(record, force)
            break
        except ToolError as error:
            if not error.rejected:
                raise
            current = STORE.read()
            if current is None:
                break  # released meanwhile: nothing left to delete
            if not force and (unreadable(current) or not STORE.holds(current, me)):
                print("NOT HOLDER: " + describe(current, at))
                lost_holding(me)
                return 4
            # The keeper's own stamp moved it (or, forcing, anyone's): delete the object now there.
            stuck = lost_race(error, record["_version"], stuck)
            record["_version"] = current["_version"]
    remove_local(None if force else me)
    print("RELEASED %s" % (record.get("branch") or record.get("purpose") or "release"))
    record_owed(owed_items, record, me, at)
    return 0


def cmd_owed(args):
    """List, settle or clear the close-out work owed after a hand-back. Local, advisory, never
    fails: any session on this machine may settle it (the one that owed it may be gone)."""
    at = now()
    entries = read_owed()
    done = options(args, "--done")
    name = option(args, "--release")
    number = option(args, "--pr")
    if done or "--clear" in args:
        # The entry to settle: the one named (by release and/or pull request); else this session's
        # newest, so a session still finishing its own close-out never settles a later release's
        # entry; else (the session that owed it is gone) the newest.
        target = entries
        if name:
            target = [e for e in target if e.get("release") == name]
        if number:
            target = [e for e in target if str(e.get("pr")) == str(pr_number(number))]
        if not name and not number:
            me, _ = holder()
            target = [e for e in entries if e.get("holder") == STORE.rid(me)] or entries
        if not target:
            print("NONE (nothing owed%s)" % (" for " + " ".join(x for x in (name, number) if x) if (name or number) else ""))
            return 0
        entry = target[-1]
        if "--clear" in args:
            entry["owed"] = []
        else:
            missing = [i for i in done if i not in entry["owed"]]
            if missing:
                progress("not owed: " + ", ".join(missing))
            entry["owed"] = [i for i in entry["owed"] if i not in done]
        entries = [e for e in entries if e["owed"]]
        write_owed(entries)
    if not entries:
        print("NONE")
        return 0
    for entry in entries:
        print("OWED " + owed_line(entry, at))
    return 0


def cmd_adopt(args):
    if "--yes" not in args:
        fail("adopt takes --yes: it rewrites the holder of a stale clearance", 1)
    me, print_token = whoami()
    at = now()
    record = STORE.read()
    if record is None:
        print("NOT HOLDER: no clearance to adopt (claim instead)")
        return 4
    if unreadable(record):
        print("ERROR: " + describe(record, at))
        return 1
    if STORE.holds(record, me):
        if renew(record, me, at) is None:
            write_local(record, me, keeper_for(me))
            print("ADOPTED (already held by this session; heartbeat renewed) %s %s" % (record.get("branch") or "-", ("#%s" % record["pr"]) if record.get("pr") else "-"))
            return 0
        record = STORE.read()
        if record is None:
            print("NOT HOLDER: no clearance to adopt (claim instead)")
            return 4
    if not is_stale(record, at):
        if not is_stuck(record, at):
            print("BUSY " + describe(record, at) + " — not stale, nothing to adopt")
            return 2
        if "--original-stopped" not in args:
            # Alive but not moving. The provider cannot prove the original session has stopped,
            # and two live sessions closing out one release send everything twice.
            print("BUSY " + describe(record, at) + " — stuck but alive: adopt only on the owner's yes, once the "
                  "original session has stopped (adopt --yes --original-stopped)")
            return 2
        progress("adopting a stuck clearance whose session was confirmed stopped: " + describe(record, at))
    if print_token:
        progress("holder token %s — export it as CLEARANCE_HOLDER_TOKEN for heartbeat and release" % me)
    previous = dict(record)
    record.update({"holder": STORE.rid(me), "user": gh_user(), "machine": claim_record.machine_name(), "heartbeatAt": iso(at),
                   "phaseStartedAt": iso(at)})
    try:
        STORE.adopt(record, previous)
    except ToolError as error:
        if not error.rejected:
            raise
        current = STORE.read()
        print("BUSY " + (describe(current, at) if current else "the clearance was released meanwhile — claim instead"))
        return 2
    write_local(record, me, start_keeper(me))
    print("ADOPTED %s %s" % (record.get("branch") or "-", ("#%s" % record["pr"]) if record.get("pr") else "-"))
    print("Resume: branch %s, pull request %s, phase %s" % (
        record.get("branch") or "none cut yet", ("#%s" % record["pr"]) if record.get("pr") else "none opened yet", record.get("phase")))
    return 0


def cmd_identity(_args):
    """The holder this session would claim with. The one verb allowed to print it: it is the
    caller's own identity, and skills need the one rule instead of a copy of it."""
    me, generated = holder()
    if generated:
        fail("no identity: set CLEARANCE_HOLDER_TOKEN (or run inside a Claude Code or Codex session)")
    print(me)
    return 0


COMMANDS = {"claim": cmd_claim, "status": cmd_status, "heartbeat": cmd_heartbeat, "release": cmd_release,
            "adopt": cmd_adopt, "owed": cmd_owed, "keeper": cmd_keeper, "identity": cmd_identity}


def main(argv):
    provider, argv = argv[0], argv[1:]
    script = "clearance-%s.sh" % provider
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: %s <claim [--wait [--ignore-stuck]] [--purpose t] | status [--short] [--json] | "
              "heartbeat <phase> [--branch b] [--pr n] | release [--force] [--owed item]... | "
              "adopt --yes [--original-stopped] | owed [--done item]... [--clear] [--release name] [--pr n] | identity>" % script)
        return 0 if argv else 1
    command = COMMANDS.get(argv[0])
    if command is None:
        fail("unknown command %s" % argv[0], 1)
    if argv[0] != "identity":
        init(provider)
    try:
        return command(argv[1:])
    except ToolError as error:
        print("ERROR: %s" % (error.text.splitlines()[0] if error.text else "a git, gh or DevStride call failed"), file=sys.stderr)
        return 1


sys.exit(main(sys.argv[1:]))
