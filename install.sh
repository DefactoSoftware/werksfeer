#!/usr/bin/env bash
# werksfeer installer
# Usage: curl -fsSL https://raw.githubusercontent.com/DefactoSoftware/werksfeer/main/install.sh | sh
set -euo pipefail

REPO="DefactoSoftware/werksfeer"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

echo "Installing werksfeer..."

# Determine install directory
if [ -w "/usr/local/bin" ]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi

# Download main script
curl -fsSL "${BASE_URL}/werksfeer" -o "${INSTALL_DIR}/werksfeer"
chmod +x "${INSTALL_DIR}/werksfeer"

# Download hook template
HOOKS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/werksfeer/hooks"
mkdir -p "$HOOKS_DIR"
curl -fsSL "${BASE_URL}/hooks/post-checkout" -o "${HOOKS_DIR}/post-checkout"
chmod +x "${HOOKS_DIR}/post-checkout"

echo ""
echo "Installed werksfeer to ${INSTALL_DIR}/werksfeer"
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

GIT HOOKS — runs automatically on "git worktree add"

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

OTHER AGENTS — run after worktree creation:

  git worktree add ../my-feature feature-branch
  cd ../my-feature
  werksfeer

  If your agent supports post-worktree hooks or setup scripts,
  point them at "werksfeer". It is idempotent and runs unattended.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

See https://github.com/DefactoSoftware/werksfeer for full documentation.
EOF
