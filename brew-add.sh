#!/usr/bin/env bash
# Usage: ./brew-add.sh <name>
# Finds <name> in the Homebrew catalogue, adds it to the matching `brews` or
# `casks` array in configuration.nix (keeping the array sorted), and commits.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FILE="$DIR/configuration.nix"

usage() {
  echo "usage: $(basename "$0") <formula-or-cask-name>" >&2
  exit 2
}

[ $# -eq 1 ] || usage
name="$1"
case "$name" in
  "" | -* | *[!A-Za-z0-9@+._/-]*) usage ;;
esac

command -v brew >/dev/null 2>&1 || { echo "brew not found on PATH" >&2; exit 1; }

# Only this script's change should end up in the commit.
if ! git -C "$DIR" diff --quiet -- configuration.nix ||
  ! git -C "$DIR" diff --cached --quiet -- configuration.nix; then
  echo "configuration.nix has uncommitted changes; commit or stash them first." >&2
  exit 1
fi

# Prints "<start> <end>": the line numbers of `    <kind> = [` and its `    ];`.
block_range() {
  awk -v open="    $1 = [" '
    $0 == open { start = NR; next }
    start && $0 == "    ];" { print start, NR; exit }
  ' "$FILE"
}

# Succeeds if "<name>" appears inside the array <kind>.
block_has() {
  local start end
  read -r start end < <(block_range "$1") || true
  [ -n "${start:-}" ] || return 1
  sed -n "$((start + 1)),$((end - 1))p" "$FILE" | grep -Fq "\"$2\""
}

add_entry() {
  local start end tmp
  read -r start end < <(block_range "$1") || true
  [ -n "${start:-}" ] || { echo "no '$1 = [' array in configuration.nix" >&2; exit 1; }
  tmp="$(mktemp)"
  {
    sed -n "1,${start}p" "$FILE"
    { sed -n "$((start + 1)),$((end - 1))p" "$FILE"; printf '      "%s"\n' "$2"; } | LC_ALL=C sort
    sed -n "${end},\$p" "$FILE"
  } > "$tmp"
  # Write through cat so configuration.nix keeps its file mode.
  cat "$tmp" > "$FILE"
  rm -f "$tmp"
}

if block_has brews "$name" || block_has casks "$name"; then
  echo "'$name' is already in configuration.nix; nothing to do."
  exit 0
fi

is_formula=false
is_cask=false
brew info --formula "$name" >/dev/null 2>&1 && is_formula=true
brew info --cask "$name" >/dev/null 2>&1 && is_cask=true

if ! $is_formula && ! $is_cask; then
  echo "No formula or cask named '$name' in the Homebrew catalogue." >&2
  matches="$(brew search "$name" 2>/dev/null | head -n 25 || true)"
  if [ -n "$matches" ]; then
    echo "Similar names:" >&2
    echo "$matches" >&2
  fi
  exit 1
fi

if $is_formula && $is_cask; then
  read -r -p "'$name' is both a formula and a cask. Add [f]ormula or [c]ask? " answer < /dev/tty
  case "$answer" in
    f | F) kind=brews ;;
    c | C) kind=casks ;;
    *) echo "aborted" >&2; exit 1 ;;
  esac
elif $is_formula; then
  kind=brews
else
  kind=casks
fi

add_entry "$kind" "$name"
git -C "$DIR" commit -q -m "Brew: added $name" -- configuration.nix

if [ "$kind" = brews ]; then label=formula; else label=cask; fi
echo "Added $label '$name' to $kind in configuration.nix and committed: brew; added $name"
echo "Run ./rebuild.sh to install it."
