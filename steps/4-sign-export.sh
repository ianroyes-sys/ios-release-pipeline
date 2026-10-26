#!/bin/bash
# Sign the archive for the App Store and export an .ipa. Every bundle in the archive (app,
# extensions, App Clip, watch app) gets an App Store profile tied to the distribution cert.
# The cert lives in a throwaway keychain that is removed from the search list on exit,
# because a leftover one breaks later signing with a keychain password prompt.
. "$(dirname "$0")/../lib.sh"
[ -d "${ARCHIVE:-}" ] || die "no archive; run the archive step first"

# 1. Profiles, one per bundle ID.
PROFILES_JSON="$WORK/profiles.json"; echo '{}' > "$PROFILES_JSON"
find "$ARCHIVE/Products/Applications" \( -name '*.app' -o -name '*.appex' \) -type d | while read -r B; do
  BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$B/Info.plist" 2>/dev/null) || continue
  NAME="AR $BID"

  BID_ID=$(asc GET "/v1/bundleIds?filter%5Bidentifier%5D=$BID&limit=200" | json "next((b['id'] for b in d['data'] if b['attributes']['identifier']=='$BID'), '')")
  if [ -z "$BID_ID" ]; then
    log "registering bundle ID $BID"
    BID_ID=$(asc POST /v1/bundleIds "{\"data\":{\"type\":\"bundleIds\",\"attributes\":{\"identifier\":\"$BID\",\"name\":\"${BID//./ }\",\"platform\":\"IOS\"}}}" | json "d['data']['id']")
  fi

  PID=$(asc GET "/v1/bundleIds/$BID_ID/profiles?limit=200" | json "next((p['id'] for p in d['data'] if p['attributes']['name']=='$NAME' and p['attributes']['profileState']=='ACTIVE' and p['attributes']['profileType']=='IOS_APP_STORE'), '')")
  if [ -n "$PID" ] && ! asc GET "/v1/profiles/$PID/certificates" | json "'$CERT_ID' in [c['id'] for c in d['data']]" | grep -q True; then
    log "profile $NAME does not carry cert $CERT_ID, replacing it"; asc DELETE "/v1/profiles/$PID" >/dev/null; PID=""
  fi
  if [ -z "$PID" ]; then
    # A stale same-name profile blocks creation; clear it first.
    for OLD in $(asc GET "/v1/bundleIds/$BID_ID/profiles?limit=200" | json "' '.join(p['id'] for p in d['data'] if p['attributes']['name']=='$NAME')"); do
      asc DELETE "/v1/profiles/$OLD" >/dev/null || true
    done
    log "creating App Store profile for $BID"
    PID=$(asc POST /v1/profiles "{\"data\":{\"type\":\"profiles\",\"attributes\":{\"name\":\"$NAME\",\"profileType\":\"IOS_APP_STORE\"},\"relationships\":{\"bundleId\":{\"data\":{\"type\":\"bundleIds\",\"id\":\"$BID_ID\"}},\"certificates\":{\"data\":[{\"type\":\"certificates\",\"id\":\"$CERT_ID\"}]}}}}" | json "d['data']['id']")
  fi

  asc GET "/v1/profiles/$PID" | python3 -c "
import sys,json,base64,os,plistlib,re
a=json.load(sys.stdin)['data']['attributes']; raw=base64.b64decode(a['profileContent'])
uuid=a['uuid']; d=os.path.expanduser('~/Library/MobileDevice/Provisioning Profiles'); os.makedirs(d,exist_ok=True)
open(f'{d}/{uuid}.mobileprovision','wb').write(raw)
m=json.load(open(sys.argv[1])); m[sys.argv[2]]=a['name']; json.dump(m,open(sys.argv[1],'w'))" "$PROFILES_JSON" "$BID"
  log "profile ready: $NAME"
done
[ "$(json "len(d)" < "$PROFILES_JSON")" -gt 0 ] || die "found no bundles in the archive"

# 2. Throwaway keychain with the distribution identity.
KC="$WORK/signing.keychain-db"; KC_PW=$(openssl rand -hex 16)
ORIG_KEYCHAINS=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')
restore() {
  # shellcheck disable=SC2086
  IFS=$'\n'; security list-keychains -d user -s $ORIG_KEYCHAINS; unset IFS
  security delete-keychain "$KC" 2>/dev/null || true
}
trap restore EXIT
rm -f "$KC"
security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KC_PW" "$KC"
security import "$SIGNING_DIR/dist.p12" -k "$KC" -P "$(cat "$SIGNING_DIR/p12.pw")" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
for g in G3 G6; do security import "$SIGNING_DIR/wwdr_$g.cer" -k "$KC" >/dev/null 2>&1 || true; done
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC" >/dev/null
IFS=$'\n'; security list-keychains -d user -s "$KC" $ORIG_KEYCHAINS; unset IFS
security find-identity -v -p codesigning "$KC" | grep -q "iPhone Distribution" || die "distribution identity did not import"

# 3. Export.
python3 - "$WORK/ExportOptions.plist" "$PROFILES_JSON" "$TEAM_ID" <<'PY'
import sys, json, plistlib
out, profiles, team = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3]
plistlib.dump({'method': 'app-store-connect', 'teamID': team, 'signingStyle': 'manual',
  'signingCertificate': 'iPhone Distribution', 'destination': 'export', 'uploadSymbols': True,
  'manageAppVersionAndBuildNumber': False, 'provisioningProfiles': profiles}, open(out, 'wb'))
PY
rm -rf "$WORK/export"
log "exporting signed .ipa"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
     -exportOptionsPlist "$WORK/ExportOptions.plist" > "$WORK/export.log" 2>&1; then
  grep -E "error|requires|entitlement" "$WORK/export.log" | sort -u | tail -20
  die "export failed (full log: $WORK/export.log). An App Group or other capability missing from the bundle ID shows up here."
fi
IPA=$(ls "$WORK"/export/*.ipa | head -1)
# Exporting an unsigned archive drops every entitlement; put each target's back (needs the keychain above).
python3 "$RELEASE_HOME/resign.py" "$IPA" "$KIND" "$CONTAINER" "$TEAM_ID" "iPhone Distribution" "$KC" \
  || die "re-signing with entitlements failed"
put IPA "$IPA"
log "signed: $(basename "$IPA") $(du -h "$IPA" | cut -f1)"
