#!/usr/bin/env bash
#
# build-ios.sh — build Open Sound Meter (psmokotnin/osm) for iOS.
#
# OSM already contains a complete iOS port (AVAudioSession audio backend, native
# document picker, Metal renderer, ARM math path). This script drives that build
# on macOS and works around two things qmake does not handle for iOS:
#
#   1. GRAPH_BACKEND defaults to OPENGL. iOS needs METAL.
#   2. The .pro compiles lib.metallib via PRE_TARGETDEPS/QMAKE_POST_LINK, both of
#      which are no-ops in generated Xcode projects (the .pro says so itself).
#      The macOS copy path is Contents/Resources/, which does not exist in an iOS
#      bundle — seriesnode.mm loads the library with
#      [[NSBundle mainBundle] pathForResource:@"lib" ofType:@"metallib"],
#      so on iOS it must land at the bundle root.
#
#   Without step 2 the app builds and launches, then dies at first chart draw.
#
# Usage:
#   ./build-ios.sh                          # device build, needs signing identity
#   TARGET=simulator ./build-ios.sh         # simulator build, no signing
#   OSM_SRC=~/src/osm ./build-ios.sh        # use an existing checkout
#
# See README.md for prerequisites and the full walkthrough.

set -euo pipefail

# ---------------------------------------------------------------- knobs -----

OSM_SRC="${OSM_SRC:-}"                       # existing checkout; cloned if empty
OSM_REF="${OSM_REF:-v1.5.2}"                 # tag/branch to build when cloning
QMAKE="${QMAKE:-}"                           # path to Qt-for-iOS qmake
BUILD_DIR="${BUILD_DIR:-$PWD/build-osm-ios}"
TARGET="${TARGET:-device}"                   # device | simulator
CONFIGURATION="${CONFIGURATION:-Release}"
BUNDLE_ID="${BUNDLE_ID:-}"                   # override app bundle identifier
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"     # 10-char Apple Developer team ID
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development}"
IOS_MIN="${IOS_MIN:-12.0}"                   # must match QMAKE_IOS_DEPLOYMENT_TARGET

RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$OFF"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '%s[warn]%s %s\n' "$YELLOW" "$OFF" "$1" >&2; }
die()  { printf '%s[error]%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }

# ------------------------------------------------------------ preflight -----

step "Preflight"

[[ "$(uname -s)" == "Darwin" ]] || die "iOS builds require macOS. Metal shader
    compilation (xcrun metal) and codesigning are Apple-only toolchains — there
    is no cross-compile path from Linux or Windows."

xcode-select -p >/dev/null 2>&1 || die "Xcode command line tools not found. Run: xcode-select --install"
command -v xcrun >/dev/null || die "xcrun not on PATH."

xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1 \
    || die "iOS SDK not available. Install Xcode (not just the CLI tools) and run:
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

# Locate a Qt-for-iOS qmake. A desktop qmake will configure but produce a macOS
# build, so verify the spec actually exists rather than trusting whatever is first
# on PATH.
if [[ -z "$QMAKE" ]]; then
    for candidate in \
        "$HOME"/Qt/*/ios/bin/qmake \
        /usr/local/Qt/*/ios/bin/qmake \
        /opt/Qt/*/ios/bin/qmake
    do
        [[ -x "$candidate" ]] && { QMAKE="$candidate"; break; }
    done
fi
[[ -n "$QMAKE" && -x "$QMAKE" ]] || die "No Qt-for-iOS qmake found.
    Install the 'iOS' target via the Qt Maintenance Tool, then set QMAKE, e.g.:
    QMAKE=~/Qt/5.15.2/ios/bin/qmake ./build-ios.sh"

QT_VERSION="$("$QMAKE" -query QT_VERSION)"
QT_SPEC_DIR="$("$QMAKE" -query QT_HOST_DATA)/mkspecs/macx-ios-clang"
[[ -d "$QT_SPEC_DIR" ]] || die "$QMAKE is not an iOS build of Qt (no macx-ios-clang mkspec).
    Point QMAKE at the qmake under your Qt installation's ios/ directory."

# OpenSoundMeter.pro hard-errors below 5.15.
qt_major="${QT_VERSION%%.*}"; qt_rest="${QT_VERSION#*.}"; qt_minor="${qt_rest%%.*}"
if (( qt_major < 5 )) || { (( qt_major == 5 )) && (( qt_minor < 15 )); }; then
    die "OSM requires Qt 5.15 or newer; found $QT_VERSION."
fi

info "macOS      $(sw_vers -productVersion)"
info "Xcode      $(xcodebuild -version | head -1)"
info "Qt         $QT_VERSION  ($QMAKE)"
info "Target     $TARGET / $CONFIGURATION"

if [[ "$TARGET" == "device" && -z "$DEVELOPMENT_TEAM" ]]; then
    warn "DEVELOPMENT_TEAM is unset. The archive step will fail unless your Xcode
       account provides an automatic signing team. Find yours with:
       security find-identity -v -p codesigning"
fi

# --------------------------------------------------------------- source -----

step "Source"

if [[ -z "$OSM_SRC" ]]; then
    OSM_SRC="$BUILD_DIR/osm"
    if [[ -d "$OSM_SRC/.git" ]]; then
        info "reusing clone at $OSM_SRC"
    else
        mkdir -p "$BUILD_DIR"
        info "cloning psmokotnin/osm @ $OSM_REF"
        git clone --branch "$OSM_REF" --depth 1 \
            https://github.com/psmokotnin/osm.git "$OSM_SRC"
    fi
fi

[[ -f "$OSM_SRC/OpenSoundMeter.pro" ]] \
    || die "OpenSoundMeter.pro not found in $OSM_SRC — is OSM_SRC pointing at the repo root?"

# The .pro derives APP_GIT_VERSION from `git describe --tags`, so a tagless or
# shallow-without-tags checkout bakes in a broken version string.
if ! git -C "$OSM_SRC" describe --tags >/dev/null 2>&1; then
    warn "no reachable git tag in $OSM_SRC; APP_GIT_VERSION will be empty.
       Fix with: git -C '$OSM_SRC' fetch --tags --unshallow"
fi

METAL_SHADER="$OSM_SRC/src/chart/metal/shaders.metal"
[[ -f "$METAL_SHADER" ]] || die "Metal shader source missing at $METAL_SHADER"

# ------------------------------------------------------- metal library ------

step "Metal shader library"

if [[ "$TARGET" == "simulator" ]]; then
    METAL_SDK="iphonesimulator"
    METAL_MIN_FLAG="-mios-simulator-version-min=$IOS_MIN"
else
    METAL_SDK="iphoneos"
    METAL_MIN_FLAG="-mios-version-min=$IOS_MIN"
fi

mkdir -p "$BUILD_DIR"
METALLIB="$BUILD_DIR/lib.metallib"
AIR="$BUILD_DIR/shaders.air"

# Mirrors the metal_command in OpenSoundMeter.pro, which only fires for Makefile
# builds. -std=ios-metal1.0 is what the .pro asks for; newer toolchains warn that
# it is deprecated but still accept it.
info "compiling shaders.metal (sdk=$METAL_SDK, min=$IOS_MIN)"
xcrun -sdk "$METAL_SDK" metal "$METAL_MIN_FLAG" -std=ios-metal1.0 \
    -c "$METAL_SHADER" -o "$AIR"
xcrun -sdk "$METAL_SDK" metallib "$AIR" -o "$METALLIB"
info "built $METALLIB"

# --------------------------------------------------------------- qmake ------

step "Generating Xcode project"

XCODE_DIR="$BUILD_DIR/xcode"
mkdir -p "$XCODE_DIR"

qmake_args=(
    "$OSM_SRC/OpenSoundMeter.pro"
    -spec macx-ios-clang
    "CONFIG+=$( [[ "$CONFIGURATION" == "Debug" ]] && echo debug || echo release )"
)
[[ -n "$BUNDLE_ID" ]] && qmake_args+=("QMAKE_TARGET_BUNDLE_PREFIX=${BUNDLE_ID%.*}")

# GRAPH_BACKEND is read via $$(GRAPH_BACKEND) — an environment variable, not a
# qmake argument. Defaults to OPENGL, which is wrong for iOS.
info "GRAPH_BACKEND=METAL"
( cd "$XCODE_DIR" && GRAPH_BACKEND=METAL "$QMAKE" "${qmake_args[@]}" )

XCODEPROJ="$XCODE_DIR/OpenSoundMeter.xcodeproj"
[[ -d "$XCODEPROJ" ]] || die "qmake did not produce $XCODEPROJ"

# ------------------------------------------------------------ xcodebuild ----

step "Building"

DERIVED="$BUILD_DIR/DerivedData"
build_args=(
    -project "$XCODEPROJ"
    -scheme OpenSoundMeter
    -configuration "$CONFIGURATION"
    -derivedDataPath "$DERIVED"
)

if [[ "$TARGET" == "simulator" ]]; then
    build_args+=(-sdk iphonesimulator -destination 'generic/platform=iOS Simulator'
                 CODE_SIGNING_ALLOWED=NO)
else
    build_args+=(-sdk iphoneos -destination 'generic/platform=iOS')
    [[ -n "$DEVELOPMENT_TEAM" ]] && build_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    [[ -n "$BUNDLE_ID" ]] && build_args+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
fi

xcodebuild "${build_args[@]}" build

APP="$(find "$DERIVED/Build/Products" -maxdepth 2 -name 'OpenSoundMeter.app' -type d -print -quit)"
[[ -n "$APP" ]] || die "build succeeded but OpenSoundMeter.app was not found under $DERIVED"
info "built $APP"

# ------------------------------------------------- inject metal library -----

step "Installing lib.metallib into the bundle"

# iOS bundles are flat: resources sit at the bundle root, not Contents/Resources.
# This is the step the .pro cannot do for Xcode-generated projects.
cp "$METALLIB" "$APP/lib.metallib"
info "installed $APP/lib.metallib"

if [[ "$TARGET" == "device" ]]; then
    # Adding a resource invalidates the signature, so re-sign the bundle.
    info "re-signing after resource injection"
    codesign --force --sign "$CODE_SIGN_IDENTITY" \
        --entitlements "$OSM_SRC/info.entitlements" \
        --timestamp=none "$APP"
    codesign --verify --verbose "$APP"
fi

# ------------------------------------------------------------- package ------

if [[ "$TARGET" == "device" ]]; then
    step "Packaging .ipa"
    PAYLOAD="$BUILD_DIR/Payload"
    rm -rf "$PAYLOAD"
    mkdir -p "$PAYLOAD"
    cp -R "$APP" "$PAYLOAD/"
    IPA="$BUILD_DIR/OpenSoundMeter-ios.ipa"
    rm -f "$IPA"
    ( cd "$BUILD_DIR" && zip -qr "$IPA" Payload )
    rm -rf "$PAYLOAD"
    info "wrote $IPA"
fi

# --------------------------------------------------------------- report -----

printf '\n%s%s Build complete%s\n' "$GREEN" "$BOLD" "$OFF"
info "app:  $APP"
[[ "$TARGET" == "device" ]] && info "ipa:  $BUILD_DIR/OpenSoundMeter-ios.ipa"

if [[ "$TARGET" == "simulator" ]]; then
    cat <<EOF

    Install and run on a booted simulator:
      xcrun simctl boot 'iPhone 15'
      xcrun simctl install booted "$APP"
      xcrun simctl launch --console booted com.opensoundmeter.OpenSoundMeter

    Note: the simulator has no real audio input, so device lists will be empty
    or synthetic. Use it to verify the UI and Metal charts render, not to measure.
EOF
else
    cat <<EOF

    Install on a connected device:
      xcrun devicectl device install app --device <udid> "$APP"

    List devices with: xcrun devicectl list devices
EOF
fi

cat <<'EOF'

    Reminder: icons/ios/*.png does not exist in the repo, so ios_icon contributes
    nothing and the app installs with a blank icon. See README.md ("App icon").
EOF
