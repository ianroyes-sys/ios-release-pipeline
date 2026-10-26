#!/bin/bash
# Run the scheme's tests on an iPhone simulator. Skips cleanly when the scheme has no tests.
# usage: 2-test.sh [auto|skip]
. "$(dirname "$0")/../lib.sh"
[ "${1:-auto}" = skip ] && { log "tests skipped by parameter"; exit 0; }

SCHEME_FILE=$(find "$CONTAINER" "$(dirname "$CONTAINER")" -maxdepth 4 -path "*xcschemes/$SCHEME.xcscheme" 2>/dev/null | head -1 || true)
if [ -z "$SCHEME_FILE" ] || ! grep -q "<TestableReference" "$SCHEME_FILE"; then
  log "scheme $SCHEME has no test targets, skipping"; exit 0
fi

SIM=$(xcrun simctl list devices available -j | python3 -c "
import sys,json
devs=[d for rt,ds in json.load(sys.stdin)['devices'].items() if 'iOS' in rt for d in ds if d['name'].startswith('iPhone')]
print(devs[-1]['udid'] if devs else '')")
[ -n "$SIM" ] || die "no available iPhone simulator (xcodebuild -downloadPlatform iOS)"

log "testing $SCHEME on simulator $SIM"
if ! xcodebuild test $KIND "$CONTAINER" -scheme "$SCHEME" -destination "id=$SIM" \
     CODE_SIGNING_ALLOWED=NO > "$WORK/test.log" 2>&1; then
  grep -E "error:|failed|FAILED" "$WORK/test.log" | tail -25
  die "tests failed (full log: $WORK/test.log)"
fi
grep -E "Executed [0-9]+ test|Test run with" "$WORK/test.log" | tail -2 || true
log "tests passed"
