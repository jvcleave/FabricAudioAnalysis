#!/bin/sh
set -eu

repository_root=$(cd "$(dirname "$0")/.." && pwd)
fabric_source_root="$repository_root/../Fabric"
scratch_path="${FABRIC_SPM_SCRATCH_PATH:-$repository_root/.fabric-spm}"
build_products="$scratch_path/$(uname -m)-apple-macosx/debug"

if ! cmp -s "$fabric_source_root/Package.resolved" "$repository_root/PluginVerification/Package.resolved"; then
    echo "PluginVerification/Package.resolved must match ../Fabric/Package.resolved" >&2
    exit 1
fi

xcrun swift build \
    --package-path "$repository_root/PluginVerification" \
    --scratch-path "$scratch_path" \
    --build-system native \
    --disable-automatic-resolution \
    --product VerifyPluginDiscovery

# The Fabric package's Hap binary refers to Sparkle but SwiftPM does not place
# that transitive framework beside a command-line executable. Copy it into
# ignored build products and clear the source checkout's quarantine on the copy.
sparkle_source="$fabric_source_root/HapInAVFoundation/external/Sparkle.framework"
sparkle_destination="$build_products/Sparkle.framework"
if [ -d "$sparkle_source" ] && [ ! -d "$sparkle_destination" ]; then
    ditto "$sparkle_source" "$sparkle_destination"
    xattr -dr com.apple.quarantine "$sparkle_destination" 2>/dev/null || :
    codesign --force --deep --sign - "$sparkle_destination"
fi

cd "$repository_root"
"$build_products/VerifyPluginDiscovery" "$@"
