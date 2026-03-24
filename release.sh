#!/usr/bin/env bash
# release.sh — Build and publish a ghostty .deb for a specific version
#
# Usage:
#   ./release.sh              # Build current pinned version
#   ./release.sh v1.3.1       # Build a specific version
#   ./release.sh latest       # Detect and build the latest stable tag
#   ./release.sh --update v1.3.1  # Replace existing release if one exists
#
set -euo pipefail

REPO="ghostty-org/ghostty"

# Parse arguments — separate --update flag from version
UPDATE=false
VERSION_ARG=""
for arg in "$@"; do
    case "$arg" in
        --update) UPDATE=true ;;
        *) VERSION_ARG="$arg" ;;
    esac
done

# Determine version
if [ "$VERSION_ARG" = "latest" ]; then
    VERSION=$(git ls-remote --tags "https://github.com/$REPO.git" \
        | grep -oP 'refs/tags/v\K[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -1)
    TAG="v$VERSION"
    echo "Latest stable: $TAG"
elif [ -n "$VERSION_ARG" ]; then
    VERSION="${VERSION_ARG#v}"
    TAG="v$VERSION"
else
    # Use whatever's in flake.nix
    TAG=$(grep 'ghostty.url' flake.nix | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
    VERSION="${TAG#v}"
    echo "Using pinned version: $TAG"
fi

echo "==> Building ghostty $TAG"

# Update the flake input to the target tag
sed -i "s|ghostty.url = \"github:ghostty-org/ghostty/v[^\"]*\"|ghostty.url = \"github:ghostty-org/ghostty/$TAG\"|" flake.nix

# Update flake lock
nix flake update ghostty

# Build
nix build .

# Find the .deb
DEB=$(find result/ -name "*.deb" -type f | head -1)
if [ -z "$DEB" ]; then
    echo "ERROR: No .deb found in result/"
    exit 1
fi

DEB_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
DEB_NAME="ghostty_${VERSION}_${DEB_ARCH}.deb"
echo "==> Built: $DEB ($DEB_NAME)"
echo ""

# Ask whether to create a GitHub release
read -rp "Create GitHub release for $TAG? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # Commit the version bump if there are changes
    if ! git diff --quiet flake.nix flake.lock; then
        git add flake.nix flake.lock
        git commit -m "Pin ghostty to $TAG"
    fi

    # Tag locally
    git tag -f "$TAG" -m "Ghostty $TAG .deb release"

    # Push
    git push origin main
    git push origin "$TAG" --force

    # Handle existing release: upload to it, replace it, or create new
    if gh release view "$TAG" &>/dev/null; then
        if [ "$UPDATE" = true ]; then
            echo "==> Deleting existing release $TAG..."
            gh release delete "$TAG" --yes
        else
            echo "==> Release $TAG exists. Uploading $DEB_NAME..."
            gh release upload "$TAG" "$DEB#$DEB_NAME" --clobber
            echo "==> Uploaded to: https://github.com/$(git remote get-url origin | sed 's|.*github.com[:/]||;s|\.git$||')/releases/tag/$TAG"
            exit 0
        fi
    fi

    # Create GitHub release with the .deb attached
    gh release create "$TAG" \
        --title "Ghostty $VERSION" \
        --notes "Ghostty $VERSION packaged as a self-contained \`.deb\` for Debian/Ubuntu (${DEB_ARCH}).

## Install

\`\`\`bash
sudo dpkg -i $DEB_NAME
\`\`\`

## What's included
- Ghostty $VERSION binary with bundled GTK4, libadwaita, and all dependencies
- JetBrains Mono font
- Shell integration (bash, zsh, fish, elvish, nushell)
- Desktop entry, icons, man pages, completions
- Uses system glibc and GPU drivers (works with NVIDIA, AMD, Intel)

## Remote hosts
If tmux/byobu fails with \`missing or unsuitable terminal: xterm-ghostty\`, copy the terminfo:
\`\`\`bash
infocmp xterm-ghostty | ssh user@remote 'tic -x -'
\`\`\`" \
        "$DEB#$DEB_NAME"

    echo "==> Release created: https://github.com/$(git remote get-url origin | sed 's|.*github.com[:/]||;s|\.git$||')/releases/tag/$TAG"
else
    echo "==> Skipped. .deb is at: $DEB"
fi
