#!/bin/bash

# Code-Notify Installation Script
# Desktop notifications for Claude Code, Codex, and Gemini CLI
# For users who want to install without Homebrew

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

echo "🔔 Code-Notify Installer"
echo "========================="
echo ""

# Detect OS
OS=$(uname -s)
case "$OS" in
    Darwin*)
        echo "Detected: macOS"
        ;;
    Linux*)
        echo "Detected: Linux"
        ;;
    CYGWIN*|MINGW*|MSYS*)
        echo "Detected: Windows (Git Bash/MSYS)"
        echo ""
        echo -e "${YELLOW}Note: For native Windows support, please use the PowerShell installer:${RESET}"
        echo "  powershell -ExecutionPolicy Bypass -File install-windows.ps1"
        echo ""
        echo "Or download and run directly:"
        echo "  irm https://raw.githubusercontent.com/xuyangy/code-notify/main/scripts/install-windows.ps1 | iex"
        echo ""
        exit 1
        ;;
    *)
        echo -e "${RED}Error: Unsupported operating system${RESET}"
        exit 1
        ;;
esac

# Check for platform-specific notification tools
echo "Checking dependencies..."

# Check for jq (required for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Warning: jq not found (required for status detection)${RESET}"
    echo "Install it with:"
    case "$OS" in
        Darwin*)
            echo "  brew install jq"
            ;;
        Linux*)
            echo "  Ubuntu/Debian: sudo apt-get install jq"
            echo "  Fedora: sudo dnf install jq"
            echo "  Arch: sudo pacman -S jq"
            ;;
    esac
    echo ""
fi

case "$OS" in
    Darwin*)
        if ! command -v terminal-notifier &> /dev/null; then
            echo -e "${YELLOW}Warning: terminal-notifier not found${RESET}"
            echo "For the best experience on macOS, install it with:"
            echo "  brew install terminal-notifier"
        fi
        ;;
    Linux*)
        if ! command -v notify-send &> /dev/null; then
            echo -e "${YELLOW}Warning: notify-send not found${RESET}"
            echo "Install it with your package manager:"
            echo "  Ubuntu/Debian: sudo apt-get install libnotify-bin"
            echo "  Fedora: sudo dnf install libnotify"
            echo "  Arch: sudo pacman -S libnotify"
        fi
        ;;
    CYGWIN*|MINGW*|MSYS*)
        echo "Windows notifications will use PowerShell"
        if ! command -v powershell &> /dev/null; then
            echo -e "${YELLOW}Warning: PowerShell not found${RESET}"
            echo "For better notifications, install BurntToast:"
            echo "  Install-Module -Name BurntToast"
        fi
        ;;
esac

# Install to user's home directory
INSTALL_DIR="$HOME/.code-notify"
echo "Installing to: $INSTALL_DIR"

mkdir -p "$HOME/.claude/notifications"

# GitHub raw URL base
GITHUB_RAW="https://raw.githubusercontent.com/xuyangy/code-notify/main"

# Resolve the repo root from this script's real on-disk location. Only treat it
# as a local checkout when the script is an actual file AND the repository
# markers are present below. This avoids false positives such as `curl | bash`
# (BASH_SOURCE is empty) or `/tmp/install.sh` (SOURCE_DIR would resolve to /,
# where /bin and /lib exist) wrongly copying unrelated system directories.
SOURCE_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# True only when SOURCE_DIR is a genuine code-notify checkout.
is_local_checkout() {
    [[ -n "$SOURCE_DIR" \
        && -f "$SOURCE_DIR/bin/code-notify" \
        && -f "$SOURCE_DIR/lib/code-notify/core/notifier.sh" ]]
}

# Files that must be present and non-empty for a usable install. Keep this in
# sync with lib/; the validation step below turns a missing entry into a hard
# error instead of a silently broken install.
REQUIRED_FILES=(
    "bin/code-notify"
    "lib/code-notify/commands/global.sh"
    "lib/code-notify/commands/project.sh"
    "lib/code-notify/core/config.sh"
    "lib/code-notify/core/notifier.sh"
    "lib/code-notify/utils/colors.sh"
    "lib/code-notify/utils/detect.sh"
    "lib/code-notify/utils/help.sh"
    "lib/code-notify/utils/voice.sh"
    "lib/code-notify/utils/tts.sh"
    "lib/code-notify/utils/sound.sh"
    "lib/code-notify/utils/channels.sh"
    "lib/code-notify/utils/usage.sh"
    "lib/code-notify/utils/click-through.sh"
    "lib/code-notify/utils/click-through-store.sh"
    "lib/code-notify/utils/click-through-runtime.sh"
    "lib/code-notify/utils/click-through-resolver.sh"
    "lib/code-notify/utils/persist.sh"
    "lib/code-notify/utils/snooze.sh"
    "lib/code-notify/utils/tmux.sh"
)

# Stage the new files in a temp dir on the SAME filesystem as the install
# target, validate them, then atomically swap into place. A network failure or
# interrupted copy can therefore never corrupt an existing installation: the
# live directory is only touched once a complete, validated tree is ready.
STAGING_DIR="$(mktemp -d "${INSTALL_DIR}.tmp.XXXXXX")"
BACKUP_DIR=""
INSTALL_ACTIVATED=0
INSTALL_COMMITTED=0
cleanup() {
    rm -rf "$STAGING_DIR"
    if [[ "$INSTALL_COMMITTED" -eq 1 ]]; then
        # Every fallible step succeeded: drop the rollback copy.
        [[ -n "$BACKUP_DIR" ]] && rm -rf "$BACKUP_DIR"
        return 0
    fi
    # Failed somewhere (including after activation, e.g. symlink setup): undo any
    # changes so the previous installation is left exactly as it was.
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        mv "$BACKUP_DIR" "$INSTALL_DIR"
    elif [[ "$INSTALL_ACTIVATED" -eq 1 ]]; then
        # Fresh install with no prior tree to restore: remove the partial one.
        rm -rf "$INSTALL_DIR"
    fi
    return 0
}
trap cleanup EXIT

abort() {
    echo -e "${RED}Error: $1${RESET}" >&2
    echo "Your existing installation was left untouched." >&2
    exit 1
}

mkdir -p "$STAGING_DIR/bin"
mkdir -p "$STAGING_DIR/lib/code-notify/commands"
mkdir -p "$STAGING_DIR/lib/code-notify/core"
mkdir -p "$STAGING_DIR/lib/code-notify/utils"

# Populate the staging dir from a local checkout when available, otherwise
# download from GitHub.
if is_local_checkout; then
    echo "Installing from local files..."
    cp -r "$SOURCE_DIR/bin/." "$STAGING_DIR/bin/"
    cp -r "$SOURCE_DIR/lib/." "$STAGING_DIR/lib/"
else
    echo "Downloading files from GitHub..."
    for rel in "${REQUIRED_FILES[@]}"; do
        if ! curl -fsSL "$GITHUB_RAW/$rel" -o "$STAGING_DIR/$rel"; then
            abort "failed to download $rel"
        fi
    done
fi

# Validate the staged tree before touching the live install.
for rel in "${REQUIRED_FILES[@]}"; do
    [[ -s "$STAGING_DIR/$rel" ]] || abort "$rel is missing or empty after staging"
done

# Catch a truncated download by syntax-checking the entrypoint.
bash -n "$STAGING_DIR/bin/code-notify" || abort "staged code-notify failed syntax check"

# Make executable.
chmod +x "$STAGING_DIR/bin/code-notify"
chmod +x "$STAGING_DIR/lib/code-notify/core/notifier.sh"

# Carry over user data stored inside the install tree so the swap below (which
# replaces the whole directory) does not discard it on update.
PRESERVE_FILES=(
    "click-through.conf"
)
for rel in "${PRESERVE_FILES[@]}"; do
    if [[ -e "$INSTALL_DIR/$rel" ]]; then
        mkdir -p "$STAGING_DIR/$(dirname "$rel")"
        cp -p "$INSTALL_DIR/$rel" "$STAGING_DIR/$rel"
    fi
done

# Atomically swap the validated tree into place.
if [[ -e "$INSTALL_DIR" ]]; then
    BACKUP_DIR="${INSTALL_DIR}.bak.$$"
    rm -rf "$BACKUP_DIR"
    mv "$INSTALL_DIR" "$BACKUP_DIR"
fi
mv "$STAGING_DIR" "$INSTALL_DIR" || abort "failed to activate new installation"
INSTALL_ACTIVATED=1

# Create symlinks in a directory that's likely in PATH
if [[ -d "$HOME/.local/bin" ]]; then
    BIN_DIR="$HOME/.local/bin"
elif [[ -d "$HOME/bin" ]]; then
    BIN_DIR="$HOME/bin"
else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
fi

# Create symlinks
ln -sf "$INSTALL_DIR/bin/code-notify" "$BIN_DIR/code-notify"
ln -sf "$INSTALL_DIR/bin/code-notify" "$BIN_DIR/cn"
ln -sf "$INSTALL_DIR/bin/code-notify" "$BIN_DIR/cnp"

# All fallible installation steps have succeeded; the new tree is now the
# committed installation and the rollback copy can be discarded on exit.
INSTALL_COMMITTED=1

# Repair stale Claude hooks from older claude-notify installs when present.
"$INSTALL_DIR/bin/code-notify" repair-hooks --quiet || true

echo -e "${GREEN}✅ Installation complete!${RESET}"
echo ""

# Check if bin directory is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo -e "${YELLOW}⚠️  Add this to your shell configuration:${RESET}"
    echo ""
    echo "  export PATH=\"\$PATH:$BIN_DIR\""
    echo ""
    echo "Add it to ~/.zshrc (zsh) or ~/.bashrc (bash)"
fi

echo "Run these commands to get started:"
echo "  code-notify setup    # Initial setup"
echo "  cn on                  # Enable notifications"
echo ""
echo "For more info: https://github.com/xuyangy/code-notify"
