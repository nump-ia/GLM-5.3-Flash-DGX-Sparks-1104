#!/usr/bin/env bash
# check-start.sh - verify a live start against the recipe's plan (KV_SHARD, PARALLEL, CONTEXT).
#
# Reads the engine's startup line in rank 0's log (default logs/current/rank0.log), then:
#   1. the served stream count matches PARALLEL,
#   2. the KV page pool is large enough for PARALLEL sessions that each fill the full
#      CONTEXT window (the overcommit case), and prints the pool's real capacity,
#   3. the prompt cache matches PROMPT_CACHE_MIN_GIB (when set),
#   4. no alarm line is present ('cannot keep one state', 'the pool holds no more pages', ...),
#   5. optionally curls /health when the API serves this host.
# Settings load the recipe's layered way (scripts/config.sh: exported > local.sh > .env > defaults),
# so run it from the recipe root with the same environment as ./start.sh.
#
# Usage: scripts/check-start.sh [logfile]     (default: logs/current/rank0.log)
# Exit:  0 healthy, 1 a check failed, 2 no startup line / unreadable log.
set -euo pipefail
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=scripts/config.sh
source "$REPO_ROOT/scripts/config.sh"

LOG=${1:-$REPO_ROOT/logs/current/rank0.log}
RANK1_LOG=$REPO_ROOT/logs/current/rank1.log
MEMGUARD_LOG=$REPO_ROOT/logs/current/memguard.log

ok()   { printf '  ok    %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }
bad()  { { printf '  FAIL  %s\n' "$1"; } >&2; failed=1; }
warn_(){ printf '  WARN  %s\n' "$1"; }
failed=0

[[ -r "$LOG" ]] || { echo "no readable rank 0 log at $LOG" >&2; exit 2; }
line=$(grep -hE ' streams? at once' "$LOG" 2>/dev/null | tail -1) || true
[[ -n "$line" ]] || { echo "no startup line ('N streams at once') in $LOG" >&2; exit 2; }

# The served stream count: '6 streams at once, ...'.
if [[ "$line" =~ ([0-9]+)\ streams\ at\ once ]]; then
  streams=${BASH_REMATCH[1]}
else
  streams=1
fi
[[ "$PARALLEL" == auto ]] && \
  { info "PARALLEL=auto; the engine serves $streams stream(s)"; } || \
  { (( streams == PARALLEL )) && ok "streams: $streams = PARALLEL=$PARALLEL" || \
      bad "streams: $streams served, PARALLEL=$PARALLEL asked (start.sh warned W_STREAMS; a stream may have been dropped for memory)"; }

# The page pool: '... taking 2056 pages of 512 rows (6.26 GiB) as they need them'.
if [[ "$line" =~ taking\ ([0-9]+)\ pages\ of\ ([0-9]+)\ rows ]]; then
  pages=${BASH_REMATCH[1]}; rows=${BASH_REMATCH[2]}
  pool_tokens=$(( pages * rows ))
  ok "KV pool: $pages pages of $rows rows = $pool_tokens tokens shared by $streams stream(s)"
  # Capacity at PARALLEL sessions that each fill the whole CONTEXT window.
  if [[ "$CONTEXT" == auto ]]; then CTX=$CONTEXT_MAX; else CTX=$CONTEXT; fi
  per=$(( (CTX + rows - 1) / rows ))          # pages one full window costs
  fits=$(( pages / per ))                     # whole windows the pool holds
  info "window: $CTX tokens = $per pages; the pool holds $fits full window(s)"
  if [[ "$PARALLEL" != auto ]] && (( PARALLEL * per > pages )); then
    bad "capacity: PARALLEL=$PARALLEL full windows need $(( PARALLEL * per )) pages, the pool holds $pages: the $(( pages / per ))-th session and every one after runs on patch 0008's reply capping; lower PARALLEL to $fits or shorten CONTEXT"
  elif [[ "$PARALLEL" != auto ]]; then
    ok "capacity: PARALLEL=$PARALLEL x $CTX tokens ($(( PARALLEL * per )) pages) fit the pool ($pages pages)"
  fi
  [[ "$KV_SHARD" == 1 ]] && info "KV_SHARD=1: latent rows live on their owner rank (about twice the pool of an unsharded start)"
elif [[ "$line" != *"as they need them"* && "$line" =~ window ]]; then
  warn_ "no shared page pool in the startup line (KV_PAGES off or KV not fp8): capacity checks need pages"
fi

# The device prompt cache: ', a 9.7 GiB prompt cache' / ', no prompt cache' (host caches read as 0 here).
cache_re='[;,] a ([0-9][0-9.]*) GiB prompt cache'
if [[ "$line" != *"GiB prompt cache in host memory"* ]] && [[ "$line" =~ $cache_re ]]; then
  cache=${BASH_REMATCH[1]}
  ok "prompt cache: $cache GiB (cap PROMPT_CACHE_GIB=$PROMPT_CACHE_GIB, CACHE_FIRST=$CACHE_FIRST)"
  if [[ -n "${PROMPT_CACHE_MIN_GIB:-}" ]] && ! python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$cache" "$PROMPT_CACHE_MIN_GIB"; then
    bad "prompt cache: $cache GiB is under PROMPT_CACHE_MIN_GIB=$PROMPT_CACHE_MIN_GIB"
  fi
else
  if [[ -n "${PROMPT_CACHE_MIN_GIB:-}" ]]; then
    bad "prompt cache: none served, PROMPT_CACHE_MIN_GIB=$PROMPT_CACHE_MIN_GIB asked for"
  else
    warn_ "no device prompt cache in the startup line (an OOM risk for long agent sessions; raise PROMPT_CACHE_GIB or MEMORY_RESERVE_GIB)"
  fi
fi

# Alarms: none of these belongs to a healthy start.
for alarm in 'cannot keep one state' 'the pool holds no more pages' 'out of memory' 'panicked'; do
  if grep -qF "$alarm" "$LOG" 2>/dev/null; then
    bad "rank 0 log: '$alarm' present ($(grep -cF "$alarm" "$LOG") time(s)); see $LOG"
  fi
done
[[ -r "$RANK1_LOG" ]] && for alarm in 'cannot keep one state' 'out of memory' 'panicked'; do
  grep -qF "$alarm" "$RANK1_LOG" && bad "rank 1 log: '$alarm' present; see $RANK1_LOG"
done
if [[ -s "$MEMGUARD_LOG" ]]; then
  warn_ "memguard wrote to $MEMGUARD_LOG; a Spark went under its available-memory floor"
fi

# The API, when it serves this host (HOST names 0.0.0.0, :: or 127.0.0.1): /health answers.
if [[ -n "${PORT:-}" ]] && [[ "$HOST" == 0.0.0.0 || "$HOST" == :: || "$HOST" == 127.0.0.1 ]]; then
  if curl -sf --max-time 5 "http://127.0.0.1:${PORT%%,*}/health" >/dev/null 2>&1; then
    ok "api: /health answers on 127.0.0.1:$PORT"
  else
    warn_ "api: /health did not answer on 127.0.0.1:$PORT (a start mid-restart is normal; otherwise check rank 0)"
  fi
fi

(( failed == 0 )) || exit 1
echo "healthy: rank 0's startup line matches the plan ($streams stream(s))"
