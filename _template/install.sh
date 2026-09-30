#!/usr/bin/env bash
# Links this agent's host files into the filenames each host looks for.
#   ./install.sh            symlink (default) — one copy of every fact on disk
#   ./install.sh --copy     independent copies, for handoff or link-averse hosts
#   ./install.sh --dry-run  print what would happen, write nothing
set -euo pipefail

cd "$(dirname "$0")"
COPY=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --copy)    COPY=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
# Dry-run is sticky: if it appears anywhere in the arguments, nothing is
# written regardless of what else was passed (e.g. flag order can't turn
# `--dry-run --copy` into a real write).
if [ "$DRY" -eq 1 ]; then
  MODE=dry
elif [ "$COPY" -eq 1 ]; then
  MODE=copy
else
  MODE=link
fi

[ -d hosts ] || { echo "no hosts/ directory here" >&2; exit 1; }

place() { # place <source> <destination>
  local src="$1" dest="$2"
  case "$MODE" in
    dry)  echo "would place $dest -> $src"; return ;;
    copy) rm -rf "$dest"; cp "$src" "$dest"; echo "copied  $dest" ;;
    link) rm -rf "$dest"; ln -s "$src" "$dest"; echo "linked  $dest" ;;
  esac
}

place hosts/CLAUDE.md CLAUDE.md
place hosts/GEMINI.md GEMINI.md
place hosts/AGENTS.md AGENTS.md

# Claude Code additionally discovers skills and agents by directory.
if [ "$MODE" != dry ]; then
  mkdir -p .claude
  rm -rf .claude/skills .claude/agents
  case "$MODE" in
    copy) cp -R skills .claude/skills; cp -R subagents .claude/agents ;;
    link) ln -s ../skills .claude/skills; ln -s ../subagents .claude/agents ;;
  esac
  echo "wired   .claude/skills and .claude/agents"
else
  echo "would wire .claude/skills and .claude/agents"
fi

echo "done ($MODE mode)"
