#!/bin/bash
# Find the Xcode project, read the app's identity, confirm the App Store Connect record
# exists, and pick the next build number. usage: 1-preflight.sh APP_DIR [SCHEME]
. "$(dirname "$0")/../lib.sh"

APP_DIR="${1:?APP_DIR required}"; SCHEME="${2:-}"
[ -d "$APP_DIR" ] || die "no such folder: $APP_DIR"
APP_DIR="$(cd "$APP_DIR" && pwd)"

# Workspace beats project (CocoaPods/SPM workspaces). Look in APP_DIR, then APP_DIR/ios.
CONTAINER=""; KIND=""
for d in "$APP_DIR" "$APP_DIR/ios"; do
  ws=$(ls -d "$d"/*.xcworkspace 2>/dev/null | head -1 || true)
  pj=$(ls -d "$d"/*.xcodeproj 2>/dev/null | head -1 || true)
  if [ -n "$ws" ]; then CONTAINER="$ws"; KIND=-workspace; break; fi
  if [ -n "$pj" ]; then CONTAINER="$pj"; KIND=-project; break; fi
done
[ -n "$CONTAINER" ] || die "no .xcworkspace or .xcodeproj in $APP_DIR or $APP_DIR/ios"
log "project: $CONTAINER"

if [ -z "$SCHEME" ]; then
  SCHEME=$(xcodebuild -list -json $KIND "$CONTAINER" 2>/dev/null | python3 -c "
import sys,json,os
d=json.load(sys.stdin); d=d.get('workspace') or d.get('project'); s=d.get('schemes',[])
base=os.path.splitext(os.path.basename(sys.argv[1]))[0]
print(base if base in s else (s[0] if s else ''))" "$CONTAINER")
fi
[ -n "$SCHEME" ] || die "could not pick a scheme; pass SCHEME"
log "scheme: $SCHEME"

# Release build settings of the scheme's application target.
read BUNDLE_ID VERSION LOCAL_BUILD TEAM PRODUCT <<<"$(xcodebuild -showBuildSettings -json $KIND "$CONTAINER" \
  -scheme "$SCHEME" -configuration Release -destination 'generic/platform=iOS' 2>/dev/null | python3 -c "
import sys,json
apps=[t['buildSettings'] for t in json.load(sys.stdin) if t['buildSettings'].get('WRAPPER_EXTENSION')=='app']
s=apps[0] if apps else {}
print(s.get('PRODUCT_BUNDLE_IDENTIFIER','-'), s.get('MARKETING_VERSION','-'), s.get('CURRENT_PROJECT_VERSION','0') or '0',
      s.get('DEVELOPMENT_TEAM','-') or '-', s.get('PRODUCT_NAME','-').replace(' ','_'))")"
[ "$BUNDLE_ID" != "-" ] || die "scheme $SCHEME has no iOS app target"
[ "$VERSION" != "-" ] || die "MARKETING_VERSION is not set on the app target"
[ "$TEAM" = "$TEAM_ID" ] || log "warning: DEVELOPMENT_TEAM is '$TEAM', signing will use $TEAM_ID"
log "app: $BUNDLE_ID  version $VERSION"

APP_ID=$(asc GET "/v1/apps?filter%5BbundleId%5D=$BUNDLE_ID" | json "next((a['id'] for a in d['data'] if a['attributes']['bundleId']=='$BUNDLE_ID'), '')")
[ -n "$APP_ID" ] || die "no App Store Connect record for $BUNDLE_ID. Create it once at appstoreconnect.apple.com (Apps, +, New App), then retry this step."
APP_NAME=$(asc GET "/v1/apps/$APP_ID" | json "d['data']['attributes']['name']")

# Build numbers must beat every build ever uploaded for the app, not just this version.
ASC_MAX=$(asc GET "/v1/builds?filter%5Bapp%5D=$APP_ID&sort=-uploadedDate&limit=200&fields%5Bbuilds%5D=version" \
  | json "max([int(b['attributes']['version']) for b in d['data'] if b['attributes']['version'].isdigit()] or [0])")
LOCAL_INT=$(printf '%s' "$LOCAL_BUILD" | tr -cd '0-9'); LOCAL_INT=${LOCAL_INT:-0}
BUILD=$(( (ASC_MAX > LOCAL_INT ? ASC_MAX : LOCAL_INT) + 1 ))
log "App Store Connect: \"$APP_NAME\" ($APP_ID), highest uploaded build $ASC_MAX, this build will be $BUILD"

OWNED=no
[ -f "$RELEASE_HOME/owned-apps.txt" ] && grep -qxF "$BUNDLE_ID" "$RELEASE_HOME/owned-apps.txt" && OWNED=yes
[ $OWNED = yes ] || log "note: $BUNDLE_ID is not in owned-apps.txt, so App Store submission will be refused (submission allowlist). TestFlight is fine."

for kv in "APP_DIR=$APP_DIR" "CONTAINER=$CONTAINER" "KIND=$KIND" "SCHEME=$SCHEME" "BUNDLE_ID=$BUNDLE_ID" \
          "VERSION=$VERSION" "BUILD=$BUILD" "PRODUCT=$PRODUCT" "APP_ID=$APP_ID" "APP_NAME=$APP_NAME" "OWNED=$OWNED"; do
  put "${kv%%=*}" "${kv#*=}"
done
echo "$APP_NAME $VERSION ($BUILD)"
