#!/bin/sh

set -eu

app=${1:?usage: sign-local-release.sh APP IDENTITY ENTITLEMENTS}
identity=${2:?usage: sign-local-release.sh APP IDENTITY ENTITLEMENTS}
entitlements=${3:?usage: sign-local-release.sh APP IDENTITY ENTITLEMENTS}

test -d "$app" || {
    echo "sign release: app not found: $app" >&2
    exit 1
}

test -f "$entitlements" || {
    echo "sign release: entitlements not found: $entitlements" >&2
    exit 1
}

security find-identity -v -p codesigning | grep -F -- "\"$identity\"" >/dev/null || {
    echo "sign release: Developer ID identity is unavailable: $identity" >&2
    exit 1
}

sign_component() {
    component=$1
    test -e "$component" || {
        echo "sign release: required component not found: $component" >&2
        exit 1
    }

    /usr/bin/codesign \
        --force \
        --sign "$identity" \
        --options runtime \
        --timestamp \
        "$component"
}

sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"

sign_component "$sparkle/XPCServices/Downloader.xpc"
sign_component "$sparkle/XPCServices/Installer.xpc"
sign_component "$sparkle/Autoupdate"
sign_component "$sparkle/Updater.app"
sign_component "$app/Contents/Frameworks/Sparkle.framework"
sign_component "$app/Contents/PlugIns/DockTilePlugin.plugin"

/usr/bin/codesign \
    --force \
    --sign "$identity" \
    --options runtime \
    --timestamp \
    --entitlements "$entitlements" \
    "$app"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

echo "sign release: signed $app"
