#!/usr/bin/env bash
# capacity.sh plans serving capacity offline: PARALLEL full CONTEXT windows against the shared KV
# page pool, with the recipe's measured pool sizes as defaults (4098 pages unsharded, 6147 with
# KV_SHARD=1 and PROMPT_CACHE_GIB>=6, 8196 with the cache spent) and --pool-pages to override with
# a real start's own figure. This test runs its cases under env -i, as kv-shard-config.sh does.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."

run() { # NAME WANT_EXIT WANT_OUTPUT_SUBSTRING [flag...] : runs scripts/capacity.sh under env -i.
  local name=$1 want=$2 want_out=$3; shift 3
  local out rc
  out=$(env -i PATH="$PATH" HOME="$HOME" WORKER=user@host \
        bash scripts/capacity.sh "$@" 2>&1) && rc=0 || rc=$?
  if (( rc == want )) && [[ "$out" == *"$want_out"* ]]; then
    echo "capacity: $name: pass (exit $rc)"
  else
    { echo "capacity: $name: FAIL (exit $rc, want $want; output missing '$want_out')"; echo "$out" | sed 's/^/  /'; } >&2
    exit 1
  fi
}

# The issue's own example: a KV_SHARD pair at PROMPT_CACHE_GIB 6 holds six 400k windows, seventh spare.
run issue-example 0 'the pool holds 7 full window(s)' \
    --context 400000 --parallel 6 --kv-shard 1 --prompt-cache-gib 6
# Unsharded, six 400k windows overcommit by 594 pages and the hint names PARALLEL=5.
run overcommit 1 'hint: PARALLEL=5 or below keeps every window whole' \
    --context 400000 --parallel 6 --kv-shard 0
run overcommit-count 1 'overcommits by 594 page(s)' \
    --context 400000 --parallel 6 --kv-shard 0
# Five 400k windows fit unsharded (the README's own number: 782 pages each, 3910 of 4098).
run five-fit 0 '5 parallel window(s) = 3910 pages' \
    --context 400000 --parallel 5 --kv-shard 0
# The ceiling: 400,000 tokens cost 782 pages, not 781 (400,000/512 = 781.25).
run ceiling 0 'one 400000-token window = 782 pages' \
    --context 400000 --parallel 1 --kv-shard 1 --prompt-cache-gib 0
# A --pool-pages override replaces the measured table and says so.
run override 0 'pool (a --pool-pages override): 4096 pages' \
    --context 400000 --parallel 2 --kv-shard 0 --pool-pages 4096
# Live contexts are counted in pages on the same grid: 300k x3 + 100k = 3 x 586 + 196 = 1954 pages.
run live-fits 0 'one more full window fits' \
    --context 400000 --parallel 4 --kv-shard 1 --prompt-cache-gib 6 --live 300000,300000,300000,100000
run live-pages 0 '= 1954 pages held of 6147' \
    --context 400000 --parallel 4 --kv-shard 1 --prompt-cache-gib 6 --live 300000,300000,300000,100000
# Seven 400k live sessions do not leave room for an eighth window on the sharded pool.
run live-over 1 'no more full window fits' \
    --context 400000 --parallel 8 --kv-shard 1 --prompt-cache-gib 6 \
    --live 400000,400000,400000,400000,400000,400000,400000
# The defaults come from scripts/config.sh: PARALLEL=4, CONTEXT=auto -> CONTEXT_MAX, KV_SHARD=0;
# four full 1M windows overcommit the measured 4098-page pool (the README's own point: the
# streams share the pool, so PARALLEL only counts requests). The window math must be exact.
run defaults 1 'one 1048576-token window = 2048 pages; 4 parallel window(s) = 8192 pages'
# Bad input dies with exit 2 and names the flag.
run bad-context 2 "CONTEXT must be a number, got 'abc'" --context abc
run bad-flag 2 'unknown flag: --nope' --nope

echo "capacity: all cases pass"
