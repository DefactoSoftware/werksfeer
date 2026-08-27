#!/usr/bin/env bash
# werksfeer installer
# Usage: curl -fsSL https://raw.githubusercontent.com/DefactoSoftware/werksfeer/main/install.sh | sh
set -euo pipefail

REPO="DefactoSoftware/werksfeer"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"

install_asset() {
  local source_path="$1"
  local destination="$2"

  if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/${source_path}" ]; then
    cp "${SCRIPT_DIR}/${source_path}" "$destination"
  else
    curl -fsSL "${BASE_URL}/${source_path}" -o "$destination"
  fi
}

echo "Installing werksfeer..."

# Determine install directory
if [ -w "/usr/local/bin" ]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi

# Download main script
install_asset "werksfeer" "${INSTALL_DIR}/werksfeer"
chmod +x "${INSTALL_DIR}/werksfeer"

# Download service modules
LIB_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/werksfeer/lib"
mkdir -p "${LIB_DIR}/services"
install_asset "lib/werksfeer/services.sh" "${LIB_DIR}/services.sh"
install_asset "lib/werksfeer/services/postgres.sh" "${LIB_DIR}/services/postgres.sh"
install_asset "lib/werksfeer/cache.sh" "${LIB_DIR}/cache.sh"

# Download hook template
HOOKS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/werksfeer/hooks"
mkdir -p "$HOOKS_DIR"
install_asset "hooks/post-checkout" "${HOOKS_DIR}/post-checkout"
chmod +x "${HOOKS_DIR}/post-checkout"

echo ""
echo "Installed werksfeer to ${INSTALL_DIR}/werksfeer"
echo "Service modules at ${LIB_DIR}"
echo "Cache module at ${LIB_DIR}/cache.sh"
echo "Hook template at ${HOOKS_DIR}/post-checkout"
echo ""

# PATH check
if ! echo "$PATH" | tr ':' '\n' | grep -qxF "$INSTALL_DIR"; then
  echo "NOTE: ${INSTALL_DIR} is not in your PATH. Add it:"
  echo ""
  echo "  # bash/zsh"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
  echo ""
  echo "  # fish"
  echo "  fish_add_path ${INSTALL_DIR}"
  echo ""
fi

cat <<EOF
Next, add a .worktree.toml to your project root (can be empty for auto-detection):

  touch .worktree.toml

Then set up werksfeer for your workflow. Pick one:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

GIT HOOKS — runs automatically on worktree creation (wt switch -c / git worktree add)

  # Global (all repos — replaces per-repo hooks):
  git config --global core.hooksPath ${HOOKS_DIR}

  # Single repo:
  cp ${HOOKS_DIR}/post-checkout /path/to/repo/.git/hooks/

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CLAUDE CODE / CLAUDE DESKTOP — add to .claude/settings.json:

  {
    "hooks": {
      "WorktreeCreate": [
        {
          "hooks": [
            {
              "type": "command",
              "command": "bash -c 'set -e; NAME=\$(cat | jq -r .name); DIR=\"\$CLAUDE_PROJECT_DIR/.worktrees/\$NAME\"; git worktree add \"\$DIR\" --detach HEAD >&2; cd \"\$DIR\" && werksfeer >&2; echo \"\$DIR\"'"
            }
          ]
        }
      ],
      "WorktreeRemove": [
        {
          "hooks": [
            {
              "type": "command",
              "command": "bash -c 'cat | jq -r .worktree_path | xargs werksfeer --cleanup'"
            }
          ]
        }
      ]
    }
  }

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CODEX APP — create .codex/setup.sh:

  #!/usr/bin/env bash
  werksfeer

  Then select it as your Local Environment setup script in the Codex app.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CURSOR — add to .cursor/worktrees.json:

  {
    "setup-worktree": [
      "werksfeer"
    ]
  }

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

WORKTRUNK (recommended) — better CLI for worktree management:

  # Install: https://github.com/max-sixty/worktrunk
  wt switch -c my-feature          # create & switch
  wt switch -x claude -c feat -- 'prompt'  # launch agent in worktree
  wt remove                        # clean up

  With git hooks configured, werksfeer runs automatically on wt switch -c.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

OTHER AGENTS — run after worktree creation:

  wt switch -c my-feature
  werksfeer

  Or with plain git:

  git worktree add ../my-feature feature-branch
  cd ../my-feature
  werksfeer

  If your agent supports post-worktree hooks or setup scripts,
  point them at "werksfeer". It is idempotent and runs unattended.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

See https://github.com/DefactoSoftware/werksfeer for full documentation.
EOF
