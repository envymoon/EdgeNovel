#!/bin/bash
# SessionStart hook for Claude Code cloud sessions: installs the Flutter SDK and
# Rust toolchain, then fetches Dart and Cargo dependencies so tests and linters
# work. Idempotent — skips anything already installed.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Matches the 3.44 line the app was created with (app/.metadata); pubspec.lock
# requires Flutter >= 3.44.0 / Dart >= 3.12.2.
FLUTTER_VERSION="3.44.9"
FLUTTER_HOME="$HOME/flutter"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# --- Rust -------------------------------------------------------------------
if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  echo "Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --component clippy,rustfmt
fi
export PATH="$HOME/.cargo/bin:$PATH"
rustup component add clippy rustfmt >/dev/null 2>&1 || true

# --- Flutter ----------------------------------------------------------------
installed_version=""
version_file="$FLUTTER_HOME/bin/cache/flutter.version.json"
if [ -f "$version_file" ]; then
  installed_version="$(sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' "$version_file")"
fi
if [ "$installed_version" != "$FLUTTER_VERSION" ]; then
  echo "Installing Flutter $FLUTTER_VERSION..."
  rm -rf "$FLUTTER_HOME"
  archive="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  curl -fsSL --retry 3 \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/$archive" \
    -o "/tmp/$archive"
  tar -xJf "/tmp/$archive" -C "$HOME"
  rm -f "/tmp/$archive"
  # The SDK is a git checkout; running as root in a container trips git's
  # ownership check.
  git config --global --add safe.directory "$FLUTTER_HOME"
fi
export PATH="$FLUTTER_HOME/bin:$PATH"
flutter config --no-analytics >/dev/null 2>&1 || true
dart --disable-analytics >/dev/null 2>&1 || true
flutter --version

# --- Project dependencies ---------------------------------------------------
(cd "$PROJECT_DIR/app" && flutter pub get)
(cd "$PROJECT_DIR/core" && cargo fetch)
(cd "$PROJECT_DIR/app/rust" && cargo fetch)

# --- Session environment ----------------------------------------------------
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$FLUTTER_HOME/bin:$HOME/.cargo/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
