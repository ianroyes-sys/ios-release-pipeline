#!/bin/bash
# Wait for Apple to process the build, clear export compliance, and put it in the internal
# TestFlight group so it shows up in the TestFlight app on your phone. Internal testing
# needs no Apple review.
. "$(dirname "$0")/../lib.sh"

BUILD_ID=""; STATE_=""
for i in $(seq 1 90); do
  read BUILD_ID STATE_ <<<"$(asc GET "/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD&limit=1" \
    | json "' '.join([d['data'][0]['id'], d['data'][0]['attributes']['processingState']]) if d['data'] else '- NOT_YET_VISIBLE'")"
  [ $((i % 5)) = 1 ] && log "build $BUILD: $STATE_"
  case $STATE_ in VALID) break ;; FAILED|INVALID) die "Apple rejected the binary while processing ($STATE_). Check the email from App Store Connect." ;; esac
  sleep 60
done
[ "$STATE_" = VALID ] || die "still processing after 90 minutes; retry this step later"
put BUILD_ID "$BUILD_ID"

asc PATCH "/v1/builds/$BUILD_ID" "{\"data\":{\"type\":\"builds\",\"id\":\"$BUILD_ID\",\"attributes\":{\"usesNonExemptEncryption\":false}}}" >/dev/null 2>&1 || true

GROUP=$(asc GET "/v1/apps/$APP_ID/betaGroups?limit=50" | json "next((g['id'] for g in d['data'] if g['attributes'].get('isInternalGroup')), '')")
if [ -z "$GROUP" ]; then
  GROUP=$(asc POST /v1/betaGroups "{\"data\":{\"type\":\"betaGroups\",\"attributes\":{\"name\":\"${TESTFLIGHT_GROUP_NAME:-Internal}\",\"isInternalGroup\":true,\"hasAccessToAllBuilds\":true},\"relationships\":{\"app\":{\"data\":{\"type\":\"apps\",\"id\":\"$APP_ID\"}}}}}" | json "d['data']['id']")
  [ -n "${TESTFLIGHT_TESTER_EMAIL:-}" ] && asc POST /v1/betaTesters "{\"data\":{\"type\":\"betaTesters\",\"attributes\":{\"email\":\"$TESTFLIGHT_TESTER_EMAIL\",\"firstName\":\"${TESTFLIGHT_TESTER_FIRST:-Dev}\",\"lastName\":\"${TESTFLIGHT_TESTER_LAST:-Tester}\"},\"relationships\":{\"betaGroups\":{\"data\":[{\"type\":\"betaGroups\",\"id\":\"$GROUP\"}]}}}}" >/dev/null 2>&1 || true
  log "created internal TestFlight group"
fi
# Groups with access to all builds reject explicit adds; that is fine.
asc POST "/v1/betaGroups/$GROUP/relationships/builds" "{\"data\":[{\"type\":\"builds\",\"id\":\"$BUILD_ID\"}]}" >/dev/null 2>&1 || true

notify "$APP_NAME $VERSION ($BUILD)" "On TestFlight. Approve App Store submission in Dagu."
log "on TestFlight: $APP_NAME $VERSION ($BUILD)"
