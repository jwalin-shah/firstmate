#!/usr/bin/env bash
# fm-index.sh — firstmate entrypoint for local agent indexing.
#
# Durable indexing logic lives in ~/.agent-rules/scripts/agent-index-maintain so
# every agent/harness uses the same manifests and safety gates. This wrapper is
# only here for firstmate convenience.
#
# Usage:
#   bin/fm-index.sh status
#   bin/fm-index.sh manifest docs
#   bin/fm-index.sh manifest transcripts
#   AGENT_INDEX_RUN_COGNEE=1 bin/fm-index.sh ingest docs
#   AGENT_INDEX_RUN_COGNEE=1 bin/fm-index.sh ingest transcripts-tier1 250

set -euo pipefail

exec "$HOME/.agent-rules/scripts/agent-index-maintain" "$@"
