#!/usr/bin/env bash
# setup-grok.test.sh -- the gate for devcontainer/setup-grok.sh
# (bdh-org/dev-common#236).
#
# That script runs at postCreate in every repo that sources it, so its failure
# modes are all of the quiet kind: nobody reads a green build log. The
# properties worth asserting are the ones a careless rewrite would break:
#
#   - a FAILED install is still non-fatal (a hard exit there breaks container
#     creation for the whole fleet) but is REPORTED as not installed -- the
#     "skipped step reads as success" shape this repo keeps writing tests about;
#   - the ~/.bashrc block is appended exactly ONCE however often setup runs,
#     since setup re-runs on every rebuild and a duplicated block is a silent
#     mess that only shows up as a slow shell;
#   - that block actually EXPORTS the key -- the whole point of the change, and
#     the half a `grok --version` check cannot see;
#   - an environment that already carries XAI_API_KEY WINS, so an explicit
#     `XAI_API_KEY=... grok ...` is not silently overridden by the file;
#   - a missing or fieldless key file WARNS rather than exporting an empty
#     string, which would look authenticated and fail at first use;
#   - the key never appears in the script's own output.
#
# Everything runs against a throwaway $HOME with PATH stubs, so no test here
# installs anything or reads the real credential.
#
# Usage:  bash tests/setup-grok.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_GROK="$REPO_ROOT/devcontainer/setup-grok.sh"

pass=0
fail=0
CASE="(none)"

# --- harness ---------------------------------------------------------------

ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s: %s\n' "$CASE" "$1"; }

# A sandbox $HOME plus a PATH holding only the stubs we put there and the
# system utilities the script uses (sed, grep, cat, npm-or-not).
new_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/stub" "$SANDBOX/.config/ai/xai" "$SANDBOX/.local/bin"
  : > "$SANDBOX/.bashrc"
  STUB_PATH="$SANDBOX/stub:/usr/local/bin:/usr/bin:/bin"
}

drop_sandbox() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }

# Runs setup-grok.sh with the sandbox as $HOME. Extra env comes in as VAR=VAL
# arguments. Captures stdout+stderr into $OUT and the exit status into $RC.
run_setup() {
  OUT="$(env -i \
    HOME="$SANDBOX" PATH="$STUB_PATH" \
    SHELL=/bin/bash TERM=dumb \
    "$@" \
    bash "$SETUP_GROK" 2>&1)"
  RC=$?
}

write_key() { printf '{"key": "%s"}\n' "$1" > "$SANDBOX/.config/ai/xai/xai.json"; }

# Sources ONLY the appended bashrc block, in a fresh shell, and prints the
# resulting XAI_API_KEY. This is what an interactive shell in the container
# does; running the whole .bashrc would drag in the rest of the setup.
eval_bashrc_block() {
  local pre="${1:-}"
  sed -n '/# --- devcontainer xai key ---/,$p' "$SANDBOX/.bashrc" \
    > "$SANDBOX/block.sh"
  env -i HOME="$SANDBOX" PATH="$STUB_PATH" ${pre:+XAI_API_KEY="$pre"} \
    bash -c '. "$HOME/block.sh"; printf "%s" "${XAI_API_KEY:-}"'
}

stub_npm_success() {
  cat > "$SANDBOX/stub/npm" <<'STUB'
#!/usr/bin/env bash
# Stands in for a real global install: drop a grok into --prefix's bin.
prefix=""
while [ $# -gt 0 ]; do
  [ "$1" = "--prefix" ] && prefix="$2"
  shift
done
mkdir -p "$prefix/bin"
cat > "$prefix/bin/grok" <<'GROK'
#!/usr/bin/env bash
echo "grok 9.9.9 (stub)"
GROK
chmod +x "$prefix/bin/grok"
STUB
  chmod +x "$SANDBOX/stub/npm"
}

stub_npm_failure() {
  printf '#!/usr/bin/env bash\necho "npm ERR! boom" >&2\nexit 1\n' \
    > "$SANDBOX/stub/npm"
  chmod +x "$SANDBOX/stub/npm"
}

# --- cases -----------------------------------------------------------------

CASE="install failure is non-fatal but reported"
new_sandbox
stub_npm_failure
write_key "xai-secretvalue"
run_setup
[ "$RC" -eq 0 ] && ok "exits 0 so postCreate survives it" \
                || notok "exit $RC would break container creation"
grep -q "NOT installed" <<<"$OUT" && ok "says NOT installed" \
                || notok "a failed install did not say so: $OUT"
drop_sandbox

CASE="GROK_INSTALL=skip"
new_sandbox
stub_npm_success
write_key "xai-secretvalue"
run_setup GROK_INSTALL=skip
[ "$RC" -eq 0 ] && ok "exits 0" || notok "exit $RC"
[ -x "$SANDBOX/.local/bin/grok" ] \
  && notok "installed something despite skip" \
  || ok "installed nothing"
grep -q "NOT installed" <<<"$OUT" && ok "still says NOT installed" \
                || notok "skip read as success: $OUT"
drop_sandbox

CASE="successful install"
new_sandbox
stub_npm_success
write_key "xai-secretvalue"
run_setup
[ "$RC" -eq 0 ] && ok "exits 0" || notok "exit $RC"
[ -x "$SANDBOX/.local/bin/grok" ] && ok "grok landed in ~/.local/bin" \
                || notok "nothing installed: $OUT"
grep -q "grok 9.9.9" <<<"$OUT" && ok "verified by running --version" \
                || notok "no version line, so the install was never proved: $OUT"
grep -q "Grok CLI ready" <<<"$OUT" && ok "reports ready" || notok "no ready line"
grep -q "xai-secretvalue" <<<"$OUT" && notok "PRINTED THE KEY" \
                || ok "never prints the key"
drop_sandbox

CASE="bashrc block"
new_sandbox
stub_npm_success
write_key "xai-secretvalue"
run_setup
run_setup                     # a rebuild runs setup again
count=$(grep -c -- "--- devcontainer xai key ---" "$SANDBOX/.bashrc")
[ "$count" -eq 1 ] && ok "appended exactly once across two runs" \
                || notok "appended $count times"
got="$(eval_bashrc_block)"
[ "$got" = "xai-secretvalue" ] && ok "exports the key from the mounted file" \
                || notok "exported '$got', wanted xai-secretvalue"
got="$(eval_bashrc_block "xai-fromenv")"
[ "$got" = "xai-fromenv" ] && ok "an existing XAI_API_KEY wins" \
                || notok "clobbered the environment with '$got'"
drop_sandbox

CASE="key file with no key field"
new_sandbox
stub_npm_success
printf '{"nope": 1}\n' > "$SANDBOX/.config/ai/xai/xai.json"
run_setup
grep -q "no \"key\" field" <<<"$OUT" && ok "warns about the unusable file" \
                || notok "said nothing about a keyless key file: $OUT"
got="$(eval_bashrc_block)"
[ -z "$got" ] && ok "exports nothing rather than an empty key" \
                || notok "exported '$got'"
drop_sandbox

CASE="no credential at all"
new_sandbox
stub_npm_success
run_setup
grep -q "no xAI credential found" <<<"$OUT" \
  && ok "names the miss instead of reporting a clean run" \
  || notok "a container with no credential looked fine: $OUT"
grep -q "grok login --device-auth" <<<"$OUT" \
  && ok "gives the recovery command" || notok "no recovery command"
drop_sandbox

# --- report ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
