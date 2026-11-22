#!/usr/bin/env bash
# capacity.sh - plan serving capacity offline: PARALLEL x CONTEXT against the KV page pool.
#
# The recipe's capacity is not one number: the shared KV page pool (512-row pages) moves with
# KV_SHARD and the prompt cache, while PARALLEL only caps the request count. This script does the
# planning arithmetic the README's memory tables imply, with the measured pool sizes as defaults:
#
#   unsharded (KV_SHARD=0)                                  ~4098 pages (2.10M tokens)
#   KV_SHARD=1 with PROMPT_CACHE_GIB 6 or more               ~6147 pages (3.15M tokens)
#   KV_SHARD=1 with the cache spent or under 6               ~8196 pages (4.20M tokens)
#
# A real start knows better: pass its startup line's own figure with --pool-pages, and verify the
# running pair against the plan with scripts/check-start.sh. The room varies by a GiB or more
# between Sparks and starts; every number here is the measured default, not a promise.
#
# Settings default the recipe's layered way (scripts/config.sh: exported > local.sh > .env >
# defaults), so a plain `scripts/capacity.sh` plans with the serving pair's own numbers; every
# flag overrides them.
#
# Usage: scripts/capacity.sh [--context N] [--parallel N] [--kv-shard 0|1]
#                            [--prompt-cache-gib N] [--pool-pages N] [--live N,N,...]
#   --context N           one request's token cap (auto resolves to CONTEXT_MAX)
#   --parallel N          the stream count to plan for (auto resolves to 8)
#   --kv-shard 0|1        KV sharding (patch 0114, TP=2 only)
#   --prompt-cache-gib N  the prompt cache to fund (picks the sharded pool's size)
#   --pool-pages N        the page count a real start reported (overrides the table)
#   --live N,N,...        live contexts of the sessions running now (pages they hold);
#                         prints whether they fit together and what a new full window costs
set -euo pipefail
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=scripts/config.sh
source "$REPO_ROOT/scripts/config.sh"

die() { printf 'capacity.sh: %s\n' "$1" >&2; exit 2; }
usage() { awk '/^# Usage:/{on=1} on && /^# /{print substr($0, 3); next} on{exit}' "$0"; }

ROWS=512
# The measured pools (README, Memory): the pair, EXL3 4 bpw, KV=fp8, KV_PAGES=on.
UNSHARDED_PAGES=4098        # 2.1M tokens, the served pair's number (KV_SHARD=0)
SHARDED_CACHE_PAGES=6147    # 3.15M tokens, KV_SHARD=1 + CACHE_FIRST=1 + PROMPT_CACHE_GIB>=6
SHARDED_FULL_PAGES=8196     # 4.2M tokens, KV_SHARD=1, the cache spent or under 6

[[ "${CONTEXT:-auto}" == auto ]] && CONTEXT=${CONTEXT_MAX:-1048576}
[[ "${PARALLEL:-auto}" == auto ]] && PARALLEL=8
[[ "${KV_SHARD:-0}" == 1 ]] || KV_SHARD=0

POSITIONAL=()
while (( $# )); do case $1 in
  --context)           CONTEXT=$2; shift 2 ;;
  --parallel)          PARALLEL=$2; shift 2 ;;
  --kv-shard)           KV_SHARD=$2; shift 2 ;;
  --prompt-cache-gib)   PROMPT_CACHE_GIB=$2; shift 2 ;;
  --pool-pages)         POOL_PAGES=$2; shift 2 ;;
  --live)               LIVE=$2; shift 2 ;;
  -h|--help)            usage; exit 0 ;;
  --*)                 die "unknown flag: $1" ;;
  *)                   POSITIONAL+=("$1"); shift ;;
esac; done
[[ ${#POSITIONAL[@]} -eq 0 ]] || die "no positional arguments: ${POSITIONAL[*]}"

for name in CONTEXT PARALLEL KV_SHARD; do
  [[ "${!name}" =~ ^[0-9]+$ ]] || die "$name must be a number, got '${!name}'"
done
(( CONTEXT >= 1 && CONTEXT <= CONTEXT_MAX )) || die "--context must be 1..$CONTEXT_MAX"
(( PARALLEL >= 1 )) || die "--parallel must be at least 1"
[[ "$KV_SHARD" == 0 || "$KV_SHARD" == 1 ]] || die "--kv-shard must be 0 or 1"

if [[ -n "${POOL_PAGES:-}" ]]; then
  [[ "$POOL_PAGES" =~ ^[0-9]+$ ]] || die "--pool-pages must be a number, got '$POOL_PAGES'"
  source='a --pool-pages override'
elif (( KV_SHARD == 0 )); then
  POOL_PAGES=$UNSHARDED_PAGES; source='the measured pair (KV_SHARD=0)'
elif (( ${PROMPT_CACHE_GIB:-0} >= 6 )); then
  POOL_PAGES=$SHARDED_CACHE_PAGES; source='the measured pair (KV_SHARD=1, PROMPT_CACHE_GIB>=6)'
else
  POOL_PAGES=$SHARDED_FULL_PAGES; source='the measured pair (KV_SHARD=1, the cache spent or under 6)'
fi

per=$(( (CONTEXT + ROWS - 1) / ROWS ))
fits=$(( POOL_PAGES / per ))
need=$(( PARALLEL * per ))

printf 'pool (%s): %d pages of %d rows = %d tokens\n' "$source" "$POOL_PAGES" "$ROWS" "$(( POOL_PAGES * ROWS ))"
printf 'one %d-token window = %d pages; %d parallel window(s) = %d pages\n' "$CONTEXT" "$per" "$PARALLEL" "$need"
rc=0
if (( need <= POOL_PAGES )); then
  printf 'fits: the pool holds %d full window(s), %d spare page(s)\n' "$fits" "$(( POOL_PAGES - need ))"
else
  # An overcommit still prints the session check: both numbers matter for the same decision.
  rc=1
  printf 'overcommits by %d page(s): the pool holds %d full window(s); the window after runs on patch 0008 reply capping (issue #3)\n' \
    "$(( need - POOL_PAGES ))" "$fits"
  (( PARALLEL > fits )) && printf 'hint: PARALLEL=%d or below keeps every window whole; or plan on up to %d tokens a window\n' \
    "$fits" "$(( (POOL_PAGES / PARALLEL) * ROWS ))"
fi

if [[ -n "${LIVE:-}" ]]; then
  used=0
  IFS=, read -r -a live_list <<< "$LIVE"
  printf 'live sessions: '
  for ctx in "${live_list[@]}"; do
    [[ "$ctx" =~ ^[0-9]+$ ]] || die "--live must be comma-separated token counts, got '$ctx'"
    used=$(( used + (ctx + ROWS - 1) / ROWS ))
    printf '%s ' "$ctx"
  done
  printf '= %d pages held of %d; one more full window needs %d\n' "$used" "$POOL_PAGES" "$per"
  if (( used + per > POOL_PAGES )); then
    rc=1
    printf 'no more full window fits; %d page(s) short\n' "$(( used + per - POOL_PAGES ))"
  else
    printf 'one more full window fits (%d page(s) spare)\n' "$(( POOL_PAGES - used - per ))"
  fi
  exit $rc
fi
exit $rc
