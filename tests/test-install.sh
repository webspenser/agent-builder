#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Symlink mode: hosts appear at the agent root as links.
cp -R _template "$WORK/link-agent"
( cd "$WORK/link-agent" && ./install.sh >/dev/null 2>&1 )
for f in CLAUDE.md GEMINI.md AGENTS.md; do
  if [ -L "$WORK/link-agent/$f" ]; then _report ok "$f is a symlink"
  else _report no "$f is not a symlink"; fi
done
if [ -f "$WORK/link-agent/.claude/agents" ] || [ -d "$WORK/link-agent/.claude" ]; then
  _report ok ".claude/ created"
else _report no ".claude/ missing"; fi

# Root link targets are exact, relative paths — not just "a link exists".
for f in CLAUDE GEMINI AGENTS; do
  target=$(readlink "$WORK/link-agent/$f.md" 2>/dev/null || true)
  if [ "$target" = "hosts/$f.md" ]; then _report ok "$f.md symlink target is hosts/$f.md"
  else _report no "$f.md symlink target is '$target', expected hosts/$f.md"; fi
done

# .claude/skills and .claude/agents: symlinks with exact relative targets
# (link mode), resolving to directories whose contents match the source.
skills_target=$(readlink "$WORK/link-agent/.claude/skills" 2>/dev/null || true)
if [ "$skills_target" = "../skills" ]; then _report ok ".claude/skills target is ../skills"
else _report no ".claude/skills target is '$skills_target', expected ../skills"; fi

agents_target=$(readlink "$WORK/link-agent/.claude/agents" 2>/dev/null || true)
if [ "$agents_target" = "../subagents" ]; then _report ok ".claude/agents target is ../subagents"
else _report no ".claude/agents target is '$agents_target', expected ../subagents"; fi

if [ -L "$WORK/link-agent/.claude/skills" ] && [ -d "$WORK/link-agent/.claude/skills" ]; then
  _report ok ".claude/skills is a symlink resolving to a directory (link mode)"
else _report no ".claude/skills is not a symlink resolving to a directory"; fi

if [ -L "$WORK/link-agent/.claude/agents" ] && [ -d "$WORK/link-agent/.claude/agents" ]; then
  _report ok ".claude/agents is a symlink resolving to a directory (link mode)"
else _report no ".claude/agents is not a symlink resolving to a directory"; fi

if diff -q <(ls -A "$WORK/link-agent/skills") <(ls -A "$WORK/link-agent/.claude/skills") >/dev/null 2>&1; then
  _report ok ".claude/skills contents match skills/"
else _report no ".claude/skills contents do not match skills/"; fi

if diff -q <(ls -A "$WORK/link-agent/subagents") <(ls -A "$WORK/link-agent/.claude/agents") >/dev/null 2>&1; then
  _report ok ".claude/agents contents match subagents/"
else _report no ".claude/agents contents do not match subagents/"; fi

# Idempotence: a second run must not fail or nest links, and the link
# targets must be unchanged — not e.g. hosts/hosts/CLAUDE.md, which
# `-L` alone would not catch.
( cd "$WORK/link-agent" && ./install.sh >/dev/null 2>&1 )
assert_pass test -L "$WORK/link-agent/CLAUDE.md"
for f in CLAUDE GEMINI AGENTS; do
  target=$(readlink "$WORK/link-agent/$f.md" 2>/dev/null || true)
  if [ "$target" = "hosts/$f.md" ]; then _report ok "$f.md target unchanged after rerun"
  else _report no "$f.md target is '$target' after rerun, expected hosts/$f.md"; fi
done
skills_target2=$(readlink "$WORK/link-agent/.claude/skills" 2>/dev/null || true)
if [ "$skills_target2" = "../skills" ]; then _report ok ".claude/skills target unchanged after rerun"
else _report no ".claude/skills target is '$skills_target2' after rerun"; fi
agents_target2=$(readlink "$WORK/link-agent/.claude/agents" 2>/dev/null || true)
if [ "$agents_target2" = "../subagents" ]; then _report ok ".claude/agents target unchanged after rerun"
else _report no ".claude/agents target is '$agents_target2' after rerun"; fi

# Copy mode: real files that survive the source being deleted.
cp -R _template "$WORK/copy-agent"
( cd "$WORK/copy-agent" && ./install.sh --copy >/dev/null 2>&1 )
for f in CLAUDE.md GEMINI.md AGENTS.md; do
  if [ -f "$WORK/copy-agent/$f" ] && [ ! -L "$WORK/copy-agent/$f" ]; then
    _report ok "$f is a real file"
  else _report no "$f is not a real file"; fi
done

if [ -d "$WORK/copy-agent/.claude/skills" ] && [ ! -L "$WORK/copy-agent/.claude/skills" ]; then
  _report ok ".claude/skills is a real directory (copy mode)"
else _report no ".claude/skills is not a real directory (copy mode)"; fi
if [ -d "$WORK/copy-agent/.claude/agents" ] && [ ! -L "$WORK/copy-agent/.claude/agents" ]; then
  _report ok ".claude/agents is a real directory (copy mode)"
else _report no ".claude/agents is not a real directory (copy mode)"; fi

rm -rf "$WORK/copy-agent/hosts" "$WORK/copy-agent/skills" "$WORK/copy-agent/subagents"
assert_contains "$WORK/copy-agent/CLAUDE.md" "AGENT.md"
if [ -d "$WORK/copy-agent/.claude/skills" ] && [ -n "$(ls -A "$WORK/copy-agent/.claude/skills" 2>/dev/null)" ]; then
  _report ok ".claude/skills survives deleting hosts/, skills/ and subagents/"
else _report no ".claude/skills did not survive source deletion"; fi

# Dry run writes nothing — the full tree, not just CLAUDE.md.
cp -R _template "$WORK/dry-agent"
( cd "$WORK/dry-agent" && ./install.sh --dry-run >/dev/null 2>&1 )
for f in CLAUDE.md GEMINI.md AGENTS.md .claude; do
  assert_fail test -e "$WORK/dry-agent/$f"
done

# Dry-run must be sticky regardless of flag order: --dry-run --copy must
# still write nothing (this was the real bug in round 1).
cp -R _template "$WORK/dry-agent2"
( cd "$WORK/dry-agent2" && ./install.sh --dry-run --copy >/dev/null 2>&1 )
for f in CLAUDE.md GEMINI.md AGENTS.md .claude; do
  assert_fail test -e "$WORK/dry-agent2/$f"
done

finish
