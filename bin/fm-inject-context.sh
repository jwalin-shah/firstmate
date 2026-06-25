#!/usr/bin/env bash
# fm-inject-context.sh — relevance-gated context injection for fm-brief.sh
#
# Reads:
#   $1  repo name (for logging only)
#   $2  project root (may be empty; we search known locations then)
#   $3  task description (the {TASK} content for keyword extraction)
#
# Prints a markdown block suitable for splicing into the brief, OR prints
# nothing if no tags matched. Stays under ~2s: no live network calls, only
# the local lang-cache and the local AGENTS.md.
#
# Algorithm:
#   1. Lowercase the task description and extract keywords:
#      - file extensions (.go, .swift, .lua, .zig, .py, .ts, .rs, .c, .cpp)
#      - language names (go, swift, lua, zig, python, rust, typescript)
#      - a curated verb/subsystem vocabulary (channel, audio, render, etc.)
#   2. Find the project's AGENTS.md (symlink target, then projects/<repo>).
#      Bail (empty output) if not found.
#   3. For each `## Heading [tags: ...]` section, compute intersection of
#      its tags with the keyword set. Inject if non-empty.
#   4. For each detected language, append the matching ~/.agent-rules/lang-cache/<lang>.md.
#
# The block is fenced under "## Project Context (auto-injected)" so the
# crewmate can tell scaffold content from filtered task context.
set -eu

REPO_NAME="${1:-}"
PROJECT_DIR="${2:-}"
TASK_DESC="${3:-}"

CACHE_DIR="${FM_LANG_CACHE_DIR:-$HOME/.agent-rules/lang-cache}"
FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- 1. Find the project's AGENTS.md ---
find_agents_md() {
  # Try the explicit PROJECT_DIR first.
  if [ -n "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/AGENTS.md" ]; then
    printf '%s' "$PROJECT_DIR/AGENTS.md"
    return 0
  fi
  # Then walk projects/<repo> symlink.
  if [ -n "$REPO_NAME" ] && [ -f "$FM_ROOT/projects/$REPO_NAME/AGENTS.md" ]; then
    printf '%s' "$FM_ROOT/projects/$REPO_NAME/AGENTS.md"
    return 0
  fi
  # Final fallback: any repo-name-prefixed fixture under FM_AGENTS_DIR
  # (used by tests; default unset so no extra surface).
  if [ -n "${FM_AGENTS_DIR:-}" ] && [ -f "${FM_AGENTS_DIR}/AGENTS.md" ]; then
    printf '%s' "${FM_AGENTS_DIR}/AGENTS.md"
    return 0
  fi
  return 1
}

AGENTS_MD="$(find_agents_md || true)"
if [ -z "$AGENTS_MD" ]; then
  # No project AGENTS.md → fall back to language cache only when languages were
  # detected in the task; otherwise emit nothing.
  AGENTS_MD=""
fi

# --- 2. Keyword extraction ---
KEYWORDS_FILE="$(mktemp)"
trap 'rm -f "$KEYWORDS_FILE"' EXIT

# Lowercase the task and emit one keyword per line.
# File extensions: keep as-is so we can match ".go" later.
printf '%s\n' "$TASK_DESC" | tr '[:upper:]' '[:lower:]' | \
  tr -cs '[:alnum:]._+#-' '\n' | sort -u > "$KEYWORDS_FILE"

# Curated verb/subsystem vocabulary. These are the tags we expect to see in
# tagged sections and the keywords that should pull them in.
COMMON_TERMS="channel audio video socket parse render cli db concurrency
wasi wasm hot-path build test arch overview error-handling codec ipc
renderer thread pool queue state machine goroutine actor async"

for term in $COMMON_TERMS; do
  # Match as a whole word in the task.
  if printf '%s' "$TASK_DESC" | grep -E -i -q "\\b${term}\\b"; then
    printf '%s\n' "$term" >> "$KEYWORDS_FILE"
  fi
done

# Detect languages via extension and via the word itself.
LANG_HITS=""
for lang in go swift zig lua python rust; do
  # Word match (e.g., "Write a Go service") OR file extension (.go).
  if printf '%s' "$TASK_DESC" | grep -E -i -q "\\b${lang}\\b|\\.${lang}\\b"; then
    LANG_HITS="$LANG_HITS $lang"
    printf '%s\n' "$lang" >> "$KEYWORDS_FILE"
  fi
done

# Deduplicate and trim.
sort -u "$KEYWORDS_FILE" -o "$KEYWORDS_FILE"

# --- 3. Inject matching tagged sections ---
emit_block() {
  if [ -z "$AGENTS_MD" ]; then
    return 0
  fi
  python3 - "$AGENTS_MD" "$KEYWORDS_FILE" <<'PYEOF'
import re, sys, pathlib
agents_path, kw_path = sys.argv[1], sys.argv[2]
keywords = {w.strip() for w in pathlib.Path(kw_path).read_text().splitlines() if w.strip()}
if not keywords:
    sys.exit(0)
text = pathlib.Path(agents_path).read_text()
# Split on top-level headings.
sections = re.split(r'(?m)^## ', text)
injected = []
for sec in sections:
    if not sec.strip():
        continue
    head, _, body = sec.partition('\n')
    head = head.strip()
    # Parse tag line: either "[tags: x, y]" or "Title [tags: x, y]".
    m = re.match(r'(.+?)\s*\[tags:\s*([^\]]*)\]', head, flags=re.IGNORECASE)
    if not m:
        # No tags: skip. We don't auto-inject untagged content.
        continue
    tags = {t.strip().lower() for t in m.group(2).split(',') if t.strip()}
    if not tags:
        continue
    if tags & keywords:
        injected.append('## ' + head + '\n' + body.rstrip())
if injected:
    sys.stdout.write('\n\n'.join(injected) + '\n')
PYEOF
}

emit_langs() {
  for lang in $LANG_HITS; do
    if [ -f "$CACHE_DIR/$lang.md" ]; then
      printf '\n\n---\n\n### Language reference: %s\n\n%s\n' "$lang" "$(cat "$CACHE_DIR/$lang.md")"
    fi
  done
}

BLOCK_BODY="$(emit_block || true)"
LANG_BODY="$(emit_langs || true)"

# If both empty, emit nothing — keeps the brief tight.
if [ -z "${BLOCK_BODY}${LANG_BODY}" ]; then
  exit 0
fi

# Wrap so the crewmate can see what was injected vs scaffolded.
printf '\n## Project Context (auto-injected)\n'
[ -n "$BLOCK_BODY" ] && printf '%s' "$BLOCK_BODY"
[ -n "$LANG_BODY" ] && printf '%s' "$LANG_BODY"
printf '\n'