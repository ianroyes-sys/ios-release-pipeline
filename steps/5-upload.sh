#!/bin/bash
# Upload the .ipa with the API key. Safe to retry: skips if ASC already has this build.
. "$(dirname "$0")/../lib.sh"
[ -f "${IPA:-}" ] || die "no .ipa; run the sign step first"

HAVE=$(asc GET "/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD&limit=1" | json "len(d['data'])")
if [ "$HAVE" != 0 ]; then log "build $BUILD is already on App Store Connect, skipping upload"; exit 0; fi

log "uploading $(basename "$IPA") ($VERSION build $BUILD)"
if ! xcrun altool --upload-app -f "$IPA" -t ios --apiKey "${ASC_KEY_ID:?set ASC_KEY_ID}" \
     --apiIssuer "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}" > "$WORK/upload.log" 2>&1; then
  tail -15 "$WORK/upload.log"
  grep -q "previousBundleVersion" "$WORK/upload.log" && die "build number collision; rerun from preflight to pick a new one"
  die "upload failed (transient timeouts are common; the step retries)"
fi
log "upload accepted"
