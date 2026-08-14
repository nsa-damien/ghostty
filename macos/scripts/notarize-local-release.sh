#!/bin/sh

set -eu

app=${1:?usage: notarize-local-release.sh APP ARCHIVE KEYCHAIN_PROFILE}
archive=${2:?usage: notarize-local-release.sh APP ARCHIVE KEYCHAIN_PROFILE}
profile=${3:?usage: notarize-local-release.sh APP ARCHIVE KEYCHAIN_PROFILE}

test -d "$app" || {
    echo "notarize release: app not found: $app" >&2
    exit 1
}

archive_dir=$(dirname -- "$archive")
mkdir -p "$archive_dir"
rm -f "$archive" "$archive.sha256"

ditto -c -k --keepParent "$app" "$archive"

submission=$(xcrun notarytool submit "$archive" \
    --keychain-profile "$profile" \
    --wait \
    --output-format json)
printf '%s\n' "$submission"

status=$(printf '%s' "$submission" | plutil -extract status raw -o - -- -)
submission_id=$(printf '%s' "$submission" | plutil -extract id raw -o - -- -)
if [ "$status" != "Accepted" ]; then
    echo "notarize release: notarization was not accepted (status: $status, id: $submission_id)" >&2
    xcrun notarytool log "$submission_id" --keychain-profile "$profile" || true
    exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"

# Stapling changes the app bundle, so package it again for distribution.
rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
archive_name=$(basename -- "$archive")
(
    cd "$archive_dir"
    shasum -a 256 "$archive_name" >"$archive_name.sha256"
)

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=4 "$app"

echo "notarize release: created $archive"
echo "notarize release: checksum $archive.sha256"
