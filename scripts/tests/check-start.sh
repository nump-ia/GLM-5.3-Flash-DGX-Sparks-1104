#!/usr/bin/env bash
# check-start.sh reads rank 0's startup line and verifies the start against the plan: the served stream
# count, the shared page pool's capacity for PARALLEL full CONTEXT windows, the funded prompt cache, and
# the alarm lines none of which belongs to a healthy start. This test runs the script on startup lines in
# the engine's own formats (as cache-min.sh assembles them), with Docker, the ranks and /health all out
# of reach (HOST set to a remote address, so the script never curls).
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT

head6='[tensorfold] CUDA sm_121 device 0 (NVIDIA GB10, memory shared with the host): model 83.29 GiB; 6 streams at once, the engine'"'"'s own and 5 more taking 6147 pages of 512 rows (18.8 GiB) as they need them (enough for three at a 1048576-token window), 417 MiB fixed each, of 20.1 GiB left after a 6.5 GiB reserve; prompts in passes of up to 4096 rows; a 4.1 GiB prompt cache; own glue kernels'
head8='[tensorfold] CUDA sm_121 device 0 (NVIDIA GB10, memory shared with the host): model 83.29 GiB; 8 streams at once, the engine'"'"'s own and 7 more taking 2056 pages of 512 rows (6.26 GiB) as they need them (enough for one at a 1048576-token window), 417 MiB fixed each, of 18.9 GiB left after a 9.5 GiB reserve; prompts in passes of up to 4096 rows; no prompt cache; own glue kernels'
# The same start truncated to two streams for the PARALLEL=2 cases.
head2='[tensorfold] CUDA sm_121 device 0 (NVIDIA GB10, memory shared with the host): model 83.29 GiB; 2 streams at once, the engine'"'"'s own and one more taking 2056 pages of 512 rows (6.26 GiB) as they need them (enough for one at a 1048576-token window), 417 MiB fixed each, of 18.9 GiB left after a 9.5 GiB reserve; prompts in passes of up to 4096 rows; no prompt cache; own glue kernels'

# got NAME LOG EXPECTED_STATUS [VAR=value...] : runs the script under env -i with the pair's defaults,
# prints its exit status. FAIL lines go to the caller's stderr with NAME.
run() {
  local name=$1 log=$2 want=$3; shift 3
  local out rc
  out=$(env -i PATH="$PATH" HOME="$HOME" WORKER=user@host HOST=10.0.34.4 KV=fp8 KV_SHARD=1 CACHE_FIRST=1 \
          CONTEXT=400000 PARALLEL=6 PROMPT_CACHE_GIB=6 "$@" \
        bash scripts/check-start.sh "$log" 2>&1) && rc=0 || rc=$?
  if (( rc == want )); then
    echo "check-start: $name: pass (exit $rc)"
  else
    { echo "check-start: $name: FAIL (exit $rc, want $want)"; echo "$out" | sed 's/^/  /'; } >&2
    exit 1
  fi
  # A failing check must say which one; a healthy one must not claim to be healthy.
  if (( want == 1 )); then
    [[ "$out" == *FAIL* ]] || { echo "check-start: $name: FAIL (exit 1 without a FAIL line)" >&2; exit 1; }
    [[ "$out" != *"healthy"* ]] || { echo "check-start: $name: FAIL (exit 1 but claims healthy)" >&2; exit 1; }
  fi
}

# Fixtures.
printf '%s\n' "$head6" > "$tmp/healthy.log"
printf '%s\n%s\n' "$head6" "kv pool: a request of 380000 prompt tokens asks 32768 reply tokens and opens with 1521: the pool holds no more pages" > "$tmp/alarm.log"
printf '%s\n' "$head8" > "$tmp/unsharded8.log"
printf '%s\n' "$head2" > "$tmp/capsmall.log"

# A healthy sharded start: 6 streams, 6147 pages, a 4.1 GiB cache, KV_SHARD=1.
run healthy "$tmp/healthy.log" 0
# The same line with a pool-alarm appended fails and names the line.
run pool-alarm "$tmp/alarm.log" 1
# An unsharded 2056-page pool cannot hold 6 full 400k windows (4692 pages): fails on capacity.
run overcommitted "$tmp/unsharded8.log" 1 PARALLEL=8
# The same log at PARALLEL=auto only reports.
run auto-reports "$tmp/unsharded8.log" 0 PARALLEL=auto
# No device prompt cache under a minimum fails; PROMPT_CACHE_MIN_GIB empty it only warns.
# At PARALLEL=2 (1564 of 2056 pages) the capacity check stays green so only the cache differs.
run cache-min "$tmp/capsmall.log" 1 PARALLEL=2 PROMPT_CACHE_MIN_GIB=4
run cache-unset "$tmp/capsmall.log" 0 PARALLEL=2
# Fewer streams served than PARALLEL asked is the W_STREAMS case, caught here too.
run stream-drop "$tmp/healthy.log" 1 PARALLEL=8
# No log at all and a log without a startup line both read as exit 2.
run missing-log "$tmp/gone.log" 2
printf 'Docker started\n' > "$tmp/nostartup.log"
run no-startup-line "$tmp/nostartup.log" 2

echo "check-start: all cases pass"
