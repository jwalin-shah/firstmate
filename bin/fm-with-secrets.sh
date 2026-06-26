#!/usr/bin/env bash
# fm-with-secrets.sh <project-slug> <task-id> <project-dir> [harness|launch-command] [--scout]
#
# Fetch Infisical secrets scoped to <project-slug> and exec fm-spawn.sh with
# a clean env (`env -i`) plus only PATH/HOME/USER/LANG/LC_ALL/TZ and the
# fetched key=value pairs. This stops firstmate's own global shell exports
# (AGENT_KEYCHAIN_SECRETS, ad-hoc *API_KEY vars, etc.) from leaking into
# every crewmate mintmux pane.
#
# Per-project scope is the matrix from data/secrets-mgmt-3q/report.md §5:
#   odysseus, odyssey-unify                   -> /providers /llm
#   inbox, agent-stack                        -> /llm /infra
#   firstmate, machine-bootstrap, tensor-logic,
#     pcr-core, btw-research, _scratch,
#     mintmux                                 -> /llm
#   default                                   -> /providers /llm
#
# Validation: ANTHROPIC_API_KEY must be present after fetch, else non-zero.
#
# Auth: sources ~/.infisical_machine.env for INFISICAL_CLIENT_ID/SECRET
# (machine-identity, non-interactive). Without it, infisical falls back to
# an interactive login which fails in a non-tty mintmux pane.
#
# This script is invoked by bin/fm-spawn.sh when FM_SECRETS_BACKEND=infisical
# is set; the flag is opt-in so default spawn behavior is unchanged.
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"
PROJ=${1:?fm-with-secrets.sh: missing project slug (arg 1)}
TASK=${2:?fm-with-secrets.sh: missing task id (arg 2)}
PROJDIR=${3:?fm-with-secrets.sh: missing project dir (arg 3)}
shift 3
# Remaining args (harness / launch command / --scout) pass through to fm-spawn.sh.

# Per-project scope matrix. Unknown projects default to /providers /llm so a
# new project's first spawn fails loud rather than silently getting too few
# keys (we want the failure to surface, not a quiet partial scope).
case "$PROJ" in
  odysseus|odyssey-unify)
    PATHS=(/providers /llm) ;;
  inbox|agent-stack)
    PATHS=(/llm /infra) ;;
  firstmate|machine-bootstrap|tensor-logic|pcr-core|btw-research|_scratch|mintmux)
    PATHS=(/llm) ;;
  *)
    PATHS=(/providers /llm) ;;
esac

# Source machine-identity env so infisical does not try an interactive login
# in a non-tty mintmux pane. If the file is missing, surface a clear message -
# never fall back to "use whatever is in the calling shell" (that would
# defeat the whole point of scoped keys).
MACHINE_ENV="$HOME/.infisical_machine.env"
if [ ! -f "$MACHINE_ENV" ]; then
  echo "error: $MACHINE_ENV not found — run 'infisical login' first, save creds to $MACHINE_ENV" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$MACHINE_ENV"

# Fetch each path into a temp dotenv file. infisical exits 0 even when a
# path is empty, so we tolerate that - the validation step below catches
# the real failure (no ANTHROPIC_API_KEY).
TMPENV=$(mktemp -t fm-secrets.XXXXXX)
trap 'rm -f "$TMPENV"' EXIT
for p in "${PATHS[@]}"; do
  infisical secrets --env dev --path "$p" --output dotenv --silent >> "$TMPENV" 2>/dev/null || true
done

# Validation: ANTHROPIC_API_KEY must be present, else abort. A missing key
# here means /llm is misconfigured in Infisical - surface that loud rather
# than launching an agent that immediately fails on a 401.
if ! grep -q '^ANTHROPIC_API_KEY=' "$TMPENV" 2>/dev/null; then
  die "$PROJ: ANTHROPIC_API_KEY not in Infisical /llm scope (paths: ${PATHS[*]})"
fi

# Build the env -i command line. env clears inherited env; we re-add only
# the harmless shell vars the agent process needs plus each KEY=VALUE from
# the temp dotenv. Using `xargs` keeps quoting safe; entries without '='
# (comments, blank lines) are skipped by grep -v '^#' + xargs handles the rest.
PRESERVE=(PATH HOME USER LANG LC_ALL TZ)
PRESERVE_ARGS=()
for v in "${PRESERVE[@]}"; do
  if [ -n "${!v-}" ]; then
    PRESERVE_ARGS+=("$v=${!v}")
  fi
done

# Hand the parsed dotenv to env as KEY=VALUE args. grep -v '^#' drops comments
# and blank lines; xargs parses one KEY=VALUE per line into separate args.
SECRET_ARGS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in '#'*) continue ;; esac
  SECRET_ARGS+=("$line")
done < "$TMPENV"

# Record the scope in state/<id>.secrets so firstmate and the teardown safety
# check can confirm the spawn got scoped keys (and how).
mkdir -p "$FM_ROOT/state"
SECRETS_META="$FM_ROOT/state/$TASK.secrets"
{
  echo "backend=infisical"
  echo "paths=${PATHS[*]}"
} > "$SECRETS_META"

# exec replaces this shell with env -i ... fm-spawn.sh ...; the agent pane
# then inherits only the filtered env.
exec env -i \
  "${PRESERVE_ARGS[@]}" \
  "${SECRET_ARGS[@]}" \
  "$FM_ROOT/bin/fm-spawn.sh" "$TASK" "$PROJDIR" "$@"
