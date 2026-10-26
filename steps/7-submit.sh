#!/bin/bash
# Submit the TestFlight build for App Store review. Runs only after a human approves in Dagu.
# usage: 7-submit.sh DECISION [WHATS_NEW]   DECISION = submit | testflight_only
. "$(dirname "$0")/../lib.sh"
DECISION="${1:-testflight_only}"; WHATS_NEW="${2:-}"

[ "$DECISION" = submit ] || { log "stopping at TestFlight as chosen"; exit 0; }
[ "$OWNED" = yes ] || die "$BUNDLE_ID is not in owned-apps.txt. Only allowlisted bundle IDs may be submitted from this account; client apps should ship from the client's own Apple account."
[ -n "${BUILD_ID:-}" ] || die "no processed build; run the testflight step first"

# 1. The App Store version to submit: reuse $VERSION, or rename an unsent draft, or create one.
read VID VSTATE <<<"$(asc GET "/v1/apps/$APP_ID/appStoreVersions?filter%5Bplatform%5D=IOS&limit=50" | python3 -c "
import sys,json
vs=[(v['id'],v['attributes']['versionString'],v['attributes'].get('appVersionState') or v['attributes'].get('appStoreState')) for v in json.load(sys.stdin)['data']]
same=[v for v in vs if v[1]=='$VERSION']
draft=[v for v in vs if v[2] in ('PREPARE_FOR_SUBMISSION','DEVELOPER_REJECTED','REJECTED','METADATA_REJECTED')]
v=(same or draft or [('-','NONE','NONE')])[0]
print(v[0], v[2] if v[1]=='$VERSION' or v[0]=='-' else 'RENAME')")"
case $VSTATE in
  READY_FOR_SALE|READY_FOR_DISTRIBUTION|PENDING_DEVELOPER_RELEASE|PROCESSING_FOR_DISTRIBUTION)
    die "version $VERSION is already released. Bump MARKETING_VERSION and run again." ;;
  WAITING_FOR_REVIEW|IN_REVIEW|ACCEPTED|PENDING_APPLE_RELEASE)
    die "version $VERSION is already with Apple ($VSTATE)." ;;
  NONE)
    VID=$(asc POST /v1/appStoreVersions "{\"data\":{\"type\":\"appStoreVersions\",\"attributes\":{\"platform\":\"IOS\",\"versionString\":\"$VERSION\"},\"relationships\":{\"app\":{\"data\":{\"type\":\"apps\",\"id\":\"$APP_ID\"}}}}}" | json "d['data']['id']")
    log "created App Store version $VERSION" ;;
  RENAME)
    asc PATCH "/v1/appStoreVersions/$VID" "{\"data\":{\"type\":\"appStoreVersions\",\"id\":\"$VID\",\"attributes\":{\"versionString\":\"$VERSION\"}}}" >/dev/null
    log "renamed the unsent draft version to $VERSION" ;;
esac

# 2. Attach the build (this also lifts a REJECTED version back to PREPARE_FOR_SUBMISSION).
asc PATCH "/v1/appStoreVersions/$VID/relationships/build" "{\"data\":{\"type\":\"builds\",\"id\":\"$BUILD_ID\"}}" >/dev/null
log "attached build $BUILD to version $VERSION"

if [ -n "$WHATS_NEW" ]; then
  LOC=$(asc GET "/v1/appStoreVersions/$VID/appStoreVersionLocalizations" | json "next((l['id'] for l in d['data'] if l['attributes']['locale'].startswith('en')), '')")
  BODY=$(python3 -c "import json,sys; print(json.dumps({'data':{'type':'appStoreVersionLocalizations','id':sys.argv[1],'attributes':{'whatsNew':sys.argv[2]}}}))" "$LOC" "$WHATS_NEW")
  if [ -n "$LOC" ] && asc PATCH "/v1/appStoreVersionLocalizations/$LOC" "$BODY" >/dev/null 2>&1; then log "set What's New"
  else log "What's New not set (Apple refuses it on an app's first version)"; fi
fi

# 3. Review submission. A rejected submission still holds the version until it is canceled.
SUBS=$(asc GET "/v1/reviewSubmissions?filter%5Bapp%5D=$APP_ID&filter%5Bplatform%5D=IOS&limit=50")
for OLD in $(echo "$SUBS" | json "' '.join(s['id'] for s in d['data'] if s['attributes']['state']=='UNRESOLVED_ISSUES')"); do
  log "canceling rejected submission $OLD so the version is free"
  asc PATCH "/v1/reviewSubmissions/$OLD" "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"$OLD\",\"attributes\":{\"canceled\":true}}}" >/dev/null
  for i in $(seq 1 20); do
    [ "$(asc GET "/v1/reviewSubmissions/$OLD" | json "d['data']['attributes']['state']")" = COMPLETE ] && break; sleep 5
  done
done
SUB=$(echo "$SUBS" | json "next((s['id'] for s in d['data'] if s['attributes']['state']=='READY_FOR_REVIEW'), '')")
[ -n "$SUB" ] || SUB=$(asc POST /v1/reviewSubmissions "{\"data\":{\"type\":\"reviewSubmissions\",\"attributes\":{\"platform\":\"IOS\"},\"relationships\":{\"app\":{\"data\":{\"type\":\"apps\",\"id\":\"$APP_ID\"}}}}}" | json "d['data']['id']")

if ! OUT=$(asc POST /v1/reviewSubmissionItems "{\"data\":{\"type\":\"reviewSubmissionItems\",\"relationships\":{\"reviewSubmission\":{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"$SUB\"}},\"appStoreVersion\":{\"data\":{\"type\":\"appStoreVersions\",\"id\":\"$VID\"}}}}}" 2>&1); then
  echo "$OUT" | grep -q ITEM_PART_OF_ANOTHER_SUBMISSION || {
    echo "$OUT" | python3 -c "
import sys,json,re
t=sys.stdin.read(); t=t[t.find('{'):]
try:
  for e in json.loads(t).get('errors',[]):
    print('-',e.get('detail') or e.get('title'))
    for k,v in (e.get('meta',{}).get('associatedErrors') or {}).items():
      for x in v: print('   ',x.get('detail') or x.get('code'))
except Exception: print(t[:1500])"
    die "Apple won't accept the version yet. Usual UI-only blockers: App Privacy label not published, first subscriptions not added for review, missing screenshots or review contact."
  }
fi

asc PATCH "/v1/reviewSubmissions/$SUB" "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"$SUB\",\"attributes\":{\"submitted\":true}}}" >/dev/null
STATE_NOW=$(asc GET "/v1/reviewSubmissions/$SUB" | json "d['data']['attributes']['state']")
notify "$APP_NAME $VERSION" "Submitted for App Store review ($STATE_NOW)"
log "submitted $APP_NAME $VERSION ($BUILD) for review: $STATE_NOW"
