#!/bin/sh
# Runs every TLC check and compares with the expected verdict.
# Usage: spec/check.sh          (all checks)
#        spec/check.sh -v NAME  (one check, full TLC output with the trace)
cd "$(dirname "$0")" || exit 1
TLC=../../tools/tlc

# spec  config  expected  meaning
CHECKS='
RateLimiter RateLimiter            ok                 global+fail_closed: TypeOK, Safety, IndInv, Liveness hold
RateLimiter RateLimiterSanity      LimitNeverReached  sanity: L calls are reachable (model not vacuous)
RateLimiter RateLimiterInductive   ok                 IndInv is inductive
RateLimiter RateLimiterNotInductive SafetyAlone       Safety alone is not inductive (CTI)
RateLimiter RateLimiterNoTimeout   Liveness           without timeout, a lost message blocks a worker forever
RateLimiter RateLimiterFailOpen    Safety             fail_open breaks safety (CAP: A over C)
RateLimiterNaive RateLimiterNaive  Safety             GET then SET: race, L+1 calls
RateLimiterLocal RateLimiterLocal  Safety             local counters: more than L
RateLimiterLocal RateLimiterLocalMax MaxNotReached    local counters: 4 workers reach exactly 4L
'

if [ "$1" = "-v" ]; then
    spec=$(echo "$CHECKS" | awk -v c="$2" '$2 == c { print $1 }')
    [ -z "$spec" ] && { echo "unknown check: $2"; exit 1; }
    exec $TLC -workers auto -config "$2.cfg" "$spec.tla"
fi

echo "$CHECKS" | {
status=0
while read -r spec cfg expected meaning; do
    [ -z "$spec" ] && continue
    out=$($TLC -workers auto -config "$cfg.cfg" "$spec.tla" 2>&1)
    if echo "$out" | grep -q "No error has been found"; then
        got=ok
    else
        got=$(echo "$out" | sed -n 's/.*Invariant \([A-Za-z]*\) is violated.*/\1/p' | head -1)
        [ -z "$got" ] && echo "$out" | grep -q "Temporal properties were violated" && got=Liveness
        [ -z "$got" ] && got=$(echo "$out" | grep -m1 "Error" || echo "?")
    fi
    if [ "$got" = "$expected" ]; then mark=PASS; else mark=FAIL; status=1; fi
    printf '%s  %-24s %s\n' "$mark" "$cfg" "$meaning"
    [ "$mark" = FAIL ] && printf '      expected %s, got %s\n' "$expected" "$got"
done
exit $status
}
