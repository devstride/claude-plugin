# Sourced (never run) by every hook command and hook script that starts Python:
#   . "${CLAUDE_PLUGIN_ROOT}/hooks/python.sh" && "$DEVSTRIDE_PY" <script> <args>
# It sets DEVSTRIDE_PY to the Python 3 to run and returns 0, or returns 1 when there is none, so
# the hook does nothing (every hook fails open).
#
# On macOS and Linux that is `python3`, found by the shell itself: no process is started.
#
# On Windows (Git for Windows' bash, where Claude Code runs hooks) `python3` is usually missing,
# or is the Microsoft Store's placeholder, which prints an error and exits. So the first of
# `py -3`, `python` and `python3` that really runs Python 3 is used, and its full path is kept
# in a small cache file so later hooks start no extra process. It also asks Python to read and
# write UTF-8 whatever the system's code page, never to leave compiled files, and puts a `python3`
# that runs it first on the search path for the session's own shell commands (through the file
# Claude Code names in CLAUDE_ENV_FILE at session start), so a skill's `python3 ...` works there
# too.

if [ -n "${DEVSTRIDE_PY:-}" ]; then
  return 0
fi
case "${OSTYPE:-}" in
  msys* | cygwin* | win32*) ;;
  *)
    command -v python3 >/dev/null 2>&1 || return 1
    DEVSTRIDE_PY=python3
    return 0
    ;;
esac

export PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1
DEVSTRIDE_PY=
_ds_py_cache="${HOME:-${USERPROFILE:-.}}/.cache/devstride-plugin"
if [ -f "$_ds_py_cache/python" ]; then
  IFS= read -r DEVSTRIDE_PY <"$_ds_py_cache/python" || DEVSTRIDE_PY=
  [ -n "$DEVSTRIDE_PY" ] && [ -f "$DEVSTRIDE_PY" ] || DEVSTRIDE_PY=
fi
_ds_py_fresh=
if [ -z "$DEVSTRIDE_PY" ]; then
  _ds_py_fresh=1
  for _ds_py_try in "py -3" python python3; do
    # shellcheck disable=SC2086  # "py -3" is a command and its argument
    # Inside a virtual environment, the Python it was made from: the path is kept for every project.
    DEVSTRIDE_PY=$($_ds_py_try -c 'import sys; sys.version_info >= (3, 8) and print(getattr(sys, "_base_executable", "") if sys.prefix != sys.base_prefix else sys.executable)' 2>/dev/null | tr -d '\r')
    [ -n "$DEVSTRIDE_PY" ] && [ -f "$DEVSTRIDE_PY" ] && break
    DEVSTRIDE_PY=
  done
  unset _ds_py_try
  if [ -z "$DEVSTRIDE_PY" ]; then
    unset _ds_py_cache _ds_py_fresh
    return 1
  fi
  if mkdir -p "$_ds_py_cache" 2>/dev/null; then
    printf '%s\n' "$DEVSTRIDE_PY" >"$_ds_py_cache/python.$$" && mv -f "$_ds_py_cache/python.$$" "$_ds_py_cache/python"
  fi
fi
# A path written into shell code is single-quoted, so a `$` or a space in it stays literal.
_ds_py_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
if { [ -n "$_ds_py_fresh" ] || [ ! -f "$_ds_py_cache/bin/python3" ]; } && mkdir -p "$_ds_py_cache/bin" 2>/dev/null; then
  printf '#!/bin/sh\nexport PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1\nexec %s "$@"\n' "$(_ds_py_q "$DEVSTRIDE_PY")" >"$_ds_py_cache/bin/python3"
  chmod +x "$_ds_py_cache/bin/python3" 2>/dev/null
fi
if [ -f "$_ds_py_cache/bin/python3" ]; then
  # A script this hook starts (a child bash) finds the same python3, ahead of the Store placeholder.
  case "$PATH" in
    "$_ds_py_cache/bin:"*) ;;
    *) PATH="$_ds_py_cache/bin:$PATH" && export PATH ;;
  esac
  # At session start, give the session's own shell commands the same python3 (once per session).
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && ! grep -qs 'devstride-plugin/bin' "$CLAUDE_ENV_FILE"; then
    printf 'export PATH=%s:"$PATH" PYTHONUTF8=1\n' "$(_ds_py_q "$_ds_py_cache/bin")" >>"$CLAUDE_ENV_FILE" 2>/dev/null
  fi
fi
unset _ds_py_cache _ds_py_fresh
unset -f _ds_py_q
return 0
