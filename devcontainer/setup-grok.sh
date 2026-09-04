#!/usr/bin/env bash
# setup-grok.sh - Grok Build CLI setup (xAI's coding agent, command `grok`)
# Source this script from your project's .devcontainer/setup.sh
#
# Usage:
#   source "$COMMON/setup-grok.sh"
#
# Installs `grok` and points it at the xAI key the devcontainer already mounts.
# The credential half of this predates the CLI by months: devcontainer.json has
# carried a ~/.config/ai/xai bind mount and XAI_API_KEY in remoteEnv since
# bdh-org/devtemplate#39, with nothing installed that reads either one.
#
# --- Install route: npm, not `curl | bash` (bdh-org/dev-common#236) ----------
# xAI documents both. npm is the default here because it needs no access to
# x.ai / storage.googleapis.com (the vendor's own stated reason for offering
# it), it does not append to ~/.bashrc behind us, and it does not put a binary
# named `agent` on PATH -- the shell installer does both of those. The Node
# feature is present in every Python repo in the fleet, so npm is there.
#
# `GROK_INSTALL=curl` selects the vendor's shell installer instead, for a
# container without npm. That path is UNVERIFIED from here: it was written from
# a reading of the published installer, not from a run of it.
#
# --- Auth: API key, container-local state ------------------------------------
# ~/.grok is deliberately NOT bind-mounted from the host. Sharing one state tree
# across every container is what corrupted ~/.claude.json (see the seeding
# comment in setup-claude.sh), and this tree also holds a ~166 MB binary and the
# session logs. So the intended credential is the API key, which xAI documents
# for exactly this case ("Scripts, CI/CD, headless automation").
#
# REVERSAL TRIGGER: if a *valid* key still leaves the CLI reporting
# "Not signed in", key auth is not usable for this CLI, and the fix is to
# persist ~/.grok/auth.json from one `grok login --device-auth` rather than to
# repeat that login in every container.
#
# --- Failure is loud, not fatal ----------------------------------------------
# Unlike Claude Code, grok is a secondary tool here, so a registry outage must
# not break container creation for the whole fleet. Every failure path below
# therefore warns and continues -- but says "NOT installed" in as many words,
# because a skipped step that reads as success is the failure this repo keeps
# writing tests about.

set -euo pipefail

GROK_INSTALL="${GROK_INSTALL:-npm}"                    # npm | curl | skip
GROK_NPM_PKG="${GROK_NPM_PKG:-@xai-official/grok}"
GROK_INSTALL_SH="${GROK_INSTALL_SH:-https://x.ai/cli/install.sh}"

# Canonical key file, matching the bind mount in devcontainer.json. Hard-coded
# rather than overridable: the bashrc block below has to name the same path, and
# it is written literally so it resolves at shell start, not at setup time.
_grok_key_file="$HOME/.config/ai/xai/xai.json"
# Both install routes end up here: npm --prefix puts its trampoline in
# ~/.local/bin, and the shell installer symlinks into the first PATH dir it
# finds writable, which is the same one. setup-base.sh already has it on PATH.
_grok_bin="$HOME/.local/bin/grok"

echo "==> Setting up Grok Build CLI..."

_grok_state=""

if command -v grok >/dev/null 2>&1; then
  _grok_state="ok"
  echo "    Grok CLI already installed"
elif [ "$GROK_INSTALL" = "skip" ]; then
  _grok_state="skipped"
  echo "    GROK_INSTALL=skip -- Grok CLI NOT installed (asked not to)"
elif [ "$GROK_INSTALL" = "npm" ]; then
  if ! command -v npm >/dev/null 2>&1; then
    _grok_state="failed"
    echo "    WARN: npm not found, so the Grok CLI is NOT installed." >&2
    echo "          Add the Node feature to devcontainer.json, or set" >&2
    echo "          GROK_INSTALL=curl to use xAI's shell installer." >&2
  # --prefix pins where this lands. Without it the target is whichever npm wins
  # on PATH -- conda's inside the python env, nvm's otherwise -- so the CLI
  # would move between containers and vanish when the conda env is rebuilt.
  elif npm install -g --prefix "$HOME/.local" "$GROK_NPM_PKG"; then
    _grok_state="ok"
  else
    _grok_state="failed"
    echo "    WARN: npm install of $GROK_NPM_PKG failed; grok is NOT installed." >&2
  fi
elif [ "$GROK_INSTALL" = "curl" ]; then
  if curl -fsSL "$GROK_INSTALL_SH" | bash; then
    _grok_state="ok"
  else
    _grok_state="failed"
    echo "    WARN: $GROK_INSTALL_SH failed; grok is NOT installed." >&2
  fi
else
  _grok_state="failed"
  echo "    WARN: GROK_INSTALL='$GROK_INSTALL' is not npm, curl or skip;" >&2
  echo "          nothing was installed." >&2
fi

# -----------------------------------------------------------------------------
# XAI_API_KEY, from the mounted key file
# -----------------------------------------------------------------------------
# remoteEnv passes ${localEnv:XAI_API_KEY} through, but that is empty unless the
# host exports it in the shell that launched the editor -- which no host here
# does. The key that actually exists is the mounted file, so read it.
#
# Its own marker, per dev-common#224: a block added inside another block's
# marker reaches no container that already ran setup, ever.
#
# sed rather than python3 on purpose -- this runs in every interactive shell,
# and an interpreter start-up there is a cost paid forever for one string.
_grok_marker="# --- devcontainer xai key ---"
if ! grep -q "$_grok_marker" "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'BASHRC_EOF'

# --- devcontainer xai key ---
# Grok Build authenticates from XAI_API_KEY where there is no browser to run
# the login flow, which is every devcontainer. An environment that already
# carries a key wins, so an explicit `XAI_API_KEY=... grok ...` still works.
if [ -z "${XAI_API_KEY:-}" ] && [ -r "$HOME/.config/ai/xai/xai.json" ]; then
  _xai_key=$(sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$HOME/.config/ai/xai/xai.json" 2>/dev/null)
  [ -n "$_xai_key" ] && export XAI_API_KEY="$_xai_key"
  unset _xai_key
fi
BASHRC_EOF
  echo "    ~/.bashrc will export XAI_API_KEY from ~/.config/ai/xai/xai.json"
else
  echo "    ~/.bashrc already exports XAI_API_KEY"
fi

# -----------------------------------------------------------------------------
# Verify, and say which credential the container will actually use
# -----------------------------------------------------------------------------
# `grok --version` is not decoration: the npm package ships a Node trampoline
# that unpacks the real binary into ~/.grok/bin on first run, so this both
# proves the install and pays that cost now rather than mid-session.
if [ "$_grok_state" = "ok" ]; then
  _grok_cmd="$_grok_bin"
  command -v "$_grok_cmd" >/dev/null 2>&1 || _grok_cmd="$(command -v grok || true)"
  if [ -n "$_grok_cmd" ] && _grok_version="$("$_grok_cmd" --version 2>&1)"; then
    echo "    $_grok_version  ($_grok_cmd)"
  else
    _grok_state="failed"
    echo "    WARN: grok is installed but would not run; treat it as NOT" >&2
    echo "          installed: ${_grok_version:-no output}" >&2
  fi
fi

# Never echo the key itself, only whether one resolved.
_grok_key=""
if [ -n "${XAI_API_KEY:-}" ]; then
  echo "    auth: XAI_API_KEY from the environment"
elif [ -r "$_grok_key_file" ]; then
  _grok_key=$(sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$_grok_key_file" 2>/dev/null || true)
  if [ -n "$_grok_key" ]; then
    echo "    auth: XAI_API_KEY from $_grok_key_file (in new shells)"
  else
    echo "    WARN: $_grok_key_file holds no \"key\" field, so grok has NO" >&2
    echo "          credential. Fix the file, or run: grok login --device-auth" >&2
  fi
elif [ -f "$HOME/.grok/auth.json" ]; then
  echo "    auth: an existing ~/.grok session"
else
  echo "    WARN: no xAI credential found -- grok will report 'Not signed in'." >&2
  echo "          Expected a key at $_grok_key_file (host-mounted), or run:" >&2
  echo "              grok login --device-auth" >&2
fi
unset _grok_key

case "$_grok_state" in
  ok)      echo "==> Grok CLI ready" ;;
  skipped) echo "==> Grok CLI setup skipped" ;;
  *)       echo "==> Grok CLI NOT installed (see the warnings above)" >&2 ;;
esac
