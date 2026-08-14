#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
makefile="$repo_root/Makefile"
project="$repo_root/macos/Ghostty.xcodeproj/project.pbxproj"
info_plist="$repo_root/macos/Ghostty-Info.plist"
update_controller="$repo_root/macos/Sources/Features/Update/UpdateController.swift"
notarize_script="$repo_root/macos/scripts/notarize-local-release.sh"
dock_plugin="$repo_root/macos/Sources/Features/Custom App Icon/DockTilePlugin.swift"
dock_notification="$repo_root/macos/Sources/Features/Custom App Icon/Extensions/Notification+AppIcon.swift"

fail() {
    echo "release contract: $*" >&2
    exit 1
}

assert_contains() {
    haystack=$1
    needle=$2
    description=$3
    printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null || fail "$description"
}

assert_not_contains() {
    haystack=$1
    needle=$2
    description=$3
    if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
        fail "$description"
    fi
}

release_output=$(make --no-print-directory -n -C "$repo_root" release)
install_output=$(make --no-print-directory -n -C "$repo_root" release-install)
sign_output=$(make --no-print-directory -n -C "$repo_root" release-sign)
notarize_output=$(make --no-print-directory -n -C "$repo_root" release-notarize)

assert_contains "$release_output" 'GHOSTTY_PRODUCT_NAME="Ghostty Dev"' \
    "release must build the Ghostty Dev product"
assert_contains "$release_output" 'GHOSTTY_DISPLAY_NAME="Ghostty Dev"' \
    "release must display the Ghostty Dev name"
assert_contains "$release_output" 'GHOSTTY_BUNDLE_IDENTIFIER="com.northshoreautomation.ghostty-dev"' \
    "release must use the Ghostty Dev bundle identifier"
assert_contains "$release_output" '-configuration ReleaseLocal' \
    "release must use the ReleaseLocal configuration"
assert_contains "$release_output" '-Dversion-string=1.3.2-sidebar.1' \
    "release must not depend on Ghostty's upstream-only tag parser"
assert_contains "$release_output" 'MARKETING_VERSION="1.3.2-sidebar.1"' \
    "release must expose the Ghostty Dev version in app metadata"

assert_contains "$install_output" 'macos/build/ReleaseLocal/Ghostty Dev.app' \
    "release install must copy the Ghostty Dev app"
assert_contains "$install_output" '/Applications/Ghostty Dev.app' \
    "release install must install Ghostty Dev separately"
assert_not_contains "$install_output" '/Applications/Ghostty.app' \
    "release install must not replace the official Ghostty app"

assert_contains "$sign_output" 'sign-local-release.sh' \
    "release-sign must use the local signing script"
assert_contains "$sign_output" 'sh test/macos/release-contract.sh' \
    "release-sign must run the release contract before signing"
assert_contains "$sign_output" 'Developer ID Application: North Shore Automation, LLC (26M5Y48BJZ)' \
    "release-sign must default to the North Shore Automation Developer ID"
assert_contains "$sign_output" 'macos/build/ReleaseLocal/Ghostty Dev.app' \
    "release-sign must sign Ghostty Dev"
assert_contains "$sign_output" '/macos/Ghostty.entitlements' \
    "distribution signing must use the hardened official entitlement set"
assert_not_contains "$sign_output" 'GhosttyReleaseLocal.entitlements' \
    "distribution signing must not disable library validation"

assert_contains "$notarize_output" 'notarize-local-release.sh' \
    "release-notarize must use the notarization script"
assert_contains "$notarize_output" 'csviewer-notary' \
    "release-notarize must use a Keychain profile"
assert_contains "$notarize_output" 'Ghostty-Dev-macos-universal.zip' \
    "release-notarize must produce the distributable archive"

assert_contains "$(cat "$project")" 'GHOSTTY_BUNDLE_IDENTIFIER = "com.northshoreautomation.ghostty-dev";' \
    "ReleaseLocal must define the Ghostty Dev bundle identifier"
assert_contains "$(cat "$project")" 'PRODUCT_BUNDLE_IDENTIFIER = "$(GHOSTTY_BUNDLE_IDENTIFIER)";' \
    "the app target must consume the custom bundle identifier"
assert_contains "$(cat "$project")" 'PRODUCT_BUNDLE_IDENTIFIER = "$(GHOSTTY_BUNDLE_IDENTIFIER).dock-tile";' \
    "the Dock plugin must use a distinct child bundle identifier"
test_host_count=$(grep -F -c 'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Ghostty Dev.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/ghostty";' "$project" || true)
[ "$test_host_count" -eq 2 ] || fail "Debug and ReleaseLocal tests must use the Ghostty Dev host"
assert_contains "$(cat "$project")" 'INFOPLIST_KEY_GhosttyEnableUpdates = "$(GHOSTTY_ENABLE_UPDATES)";' \
    "custom builds must carry their update policy in Info.plist"
assert_contains "$(cat "$project")" 'GHOSTTY_ENABLE_UPDATES = YES;' \
    "official release builds must retain upstream updates"
assert_contains "$(cat "$info_plist")" '<key>GhosttyEnableUpdates</key>' \
    "the source Info.plist must declare the custom update policy"
assert_contains "$(cat "$update_controller")" 'static var isEnabled: Bool' \
    "the updater must honor the custom build update policy"
assert_contains "$(cat "$update_controller")" 'if value.length == 0 { return true }' \
    "an unset policy must preserve official update behavior"
assert_contains "$(cat "$dock_plugin")" 'com.northshoreautomation.ghostty-dev' \
    "the custom Dock plugin must use Ghostty Dev defaults"
assert_contains "$(cat "$dock_notification")" 'com.northshoreautomation.ghostty-dev.iconDidChange' \
    "the custom Dock notification must not collide with official Ghostty"
assert_contains "$(cat "$notarize_script")" 'notarization was not accepted' \
    "notarization must fail unless Apple explicitly accepts the submission"
assert_contains "$(cat "$notarize_script")" 'basename -- "$archive"' \
    "the checksum must remain portable after copying the distribution files"

if grep -E '(PASSWORD|TOKEN|SECRET|PRIVATE_KEY|API_KEY|ISSUER)[[:space:]]*[:?+]?=[[:space:]]*[^$[:space:]]' \
    "$makefile" "$repo_root"/macos/scripts/*.sh 2>/dev/null; then
    fail "release automation must not contain plaintext secrets"
fi

if grep -R -F -- '-----BEGIN' "$makefile" "$repo_root/macos/scripts" 2>/dev/null; then
    fail "release automation must not contain private key material"
fi

echo "release contract: ok"
