#!/bin/bash
# Unsigned Release archive with the build number stamped in. Signing happens at export.
. "$(dirname "$0")/../lib.sh"

ARCHIVE="$WORK/$PRODUCT.xcarchive"
rm -rf "$ARCHIVE"
log "archiving $SCHEME as $VERSION ($BUILD)"
if ! xcodebuild archive $KIND "$CONTAINER" -scheme "$SCHEME" -configuration Release \
     -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
     CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=$TEAM_ID CURRENT_PROJECT_VERSION=$BUILD \
     > "$WORK/archive.log" 2>&1; then
  grep -E "error:" "$WORK/archive.log" | sort -u | tail -25
  die "archive failed (full log: $WORK/archive.log)"
fi

APP=$(ls -d "$ARCHIVE"/Products/Applications/*.app | head -1)
GOT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
[ "$GOT" = "$BUILD" ] || die "archived CFBundleVersion is '$GOT', expected $BUILD. Info.plist hardcodes it; set it to \$(CURRENT_PROJECT_VERSION)."
put ARCHIVE "$ARCHIVE"
log "archive OK: $(du -sh "$ARCHIVE" | cut -f1)"
