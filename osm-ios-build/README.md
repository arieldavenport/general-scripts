# osm-ios-build

> Builds [Open Sound Meter](https://github.com/psmokotnin/osm) for iOS from source
> on macOS, working around the two qmake gaps that otherwise produce an app which
> launches and then crashes on the first chart draw.

**Read this first:** OSM **already ships an iOS app**. It has been on the App
Store since July 2021 — [Open Sound Meter, app ID 1552933259](https://apps.apple.com/us/app/open-sound-meter/id1552933259),
currently v1.5.2, iPhone + iPad, iOS 12.0+, paid. If you just want the app on
your phone, buy it and support the author. This project exists for the cases
where building from source is the point: you want to modify it, you want a build
for a device you can't ship to, or you want to verify what you're running.

OSM is GPL-3, so building and installing your own copy is squarely within your
rights.

## Building instead of buying: do the arithmetic first

Building from source to avoid the App Store price is legitimate — GPL-3 grants
exactly that right, and the published source is the current shipping code. But it
is frequently *more* expensive than the app:

| Requirement | Cost |
|---|---|
| Mac with Xcode | Xcode is free; the Mac is not. There is no cross-compile path. |
| Qt for iOS | Free (open-source builds). |
| Apple Developer account — **free tier** | $0, but provisioning profiles **expire after 7 days**. The app stops launching and must be rebuilt and reinstalled weekly, with the Mac and device in hand. |
| Apple Developer account — **paid tier** | **$99/year** — recurring, versus a one-time App Store purchase. |

Rules of thumb:

- **Mac + paid developer account already?** Building costs nothing extra. Go ahead.
- **Mac, no developer account?** Free-tier signing works, but you re-sign every
  7 days indefinitely. Tools like AltStore/SideStore automate this over Wi-Fi.
- **No Mac?** Buying the app is far cheaper than the hardware.

You also give up App Store auto-updates, and this script is untested on macOS
(see Notes) — budget time for the first build.

## Why this project exists

There is **no iOS port to write**. The upstream tree already contains a complete,
production-grade iOS implementation:

| iOS component | Where |
|---|---|
| Audio I/O — AVAudioSession: permissions, `PlayAndRecord`, Bluetooth/AirPlay routing, interruption + route-change + background handling | `src/audio/plugins/audiosession.mm` |
| File dialogs — native document picker | `src/filesystem/plugins/iosdialogplugin.mm` |
| Rendering — Metal scene-graph nodes, `iphoneos` shader target | `src/chart/metal/`, `shaders.metal` |
| DSP — ARM math path (selected when `QT_ARCH=arm64`) | `src/armmath.h` |
| Target config — deployment 12.0, arm64, iPhone + iPad | `OpenSoundMeter.pro`, `ios:` block |
| Permissions | `Info.plist`: `NSMicrophoneUsageDescription`, `UISupportsDocumentBrowser` |

The upstream README's "**Supported systems:** macOS, Windows, Linux" line is
simply out of date, which is what makes the project look desktop-only.

What *is* missing is a working build path. Two things bite:

1. **`GRAPH_BACKEND` defaults to `OPENGL`.** `OpenSoundMeter.pro` reads it from
   the *environment* (`$$(GRAPH_BACKEND)`), not from a qmake argument, and falls
   back to OpenGL. OpenGL ES is deprecated on iOS; the shipping app uses Metal.

2. **`lib.metallib` never reaches the bundle.** The `.pro` compiles the Metal
   library through `PRE_TARGETDEPS` and `QMAKE_POST_LINK` — both of which are
   no-ops in generated Xcode projects, as a comment in the `.pro` itself notes:

   ```
   #QMAKE_POST_LINK and PRE_TARGETDEPS - takes no effect on Xcode projects
   ```

   Its copy destination is `OpenSoundMeter.app/Contents/Resources/`, the **macOS**
   bundle layout. iOS bundles are flat, and `seriesnode.mm` looks the library up
   at the bundle root:

   ```objc
   NSString *libraryFile = [[NSBundle mainBundle] pathForResource:@"lib" ofType:@"metallib"];
   ```

   Miss this and the build succeeds, the app launches, and it dies the moment a
   plot tries to render.

`build-ios.sh` sets the backend, compiles the shader library with the correct SDK,
and installs it at the bundle root — then re-signs, because adding a resource
invalidates the signature.

## Files

| File | Purpose |
|------|---------|
| `build-ios.sh` | End-to-end build: preflight, clone/locate source, compile `lib.metallib`, generate the Xcode project, `xcodebuild`, inject the shader library, re-sign, package `.ipa`. |
| `README.md` | This file. |

## Prerequisites

- **macOS.** Non-negotiable. `xcrun metal` and codesigning are Apple-only
  toolchains — there is no cross-compile path from Linux or Windows. The script
  refuses to run anywhere else.
- **Xcode** (the full app, not just Command Line Tools) with the iOS SDK, and
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- **Qt for iOS**, 5.15 or newer — `OpenSoundMeter.pro` hard-errors below 5.15.
  Install the *iOS* target via the Qt Maintenance Tool; a desktop Qt will
  configure but silently build for macOS. The script verifies the
  `macx-ios-clang` mkspec is actually present.
- **Apple Developer account** for device installs. Free accounts work but the
  provisioning profile expires after 7 days. Not needed for simulator builds.
- `git` and `zip` (both ship with macOS).

## Usage

```bash
# Simulator build — no signing, no developer account. Best first smoke test.
TARGET=simulator ./build-ios.sh

# Device build + .ipa
DEVELOPMENT_TEAM=ABCDE12345 ./build-ios.sh

# Build a specific ref, into your own bundle ID, from an existing checkout
OSM_SRC=~/src/osm \
BUNDLE_ID=com.example.osm \
DEVELOPMENT_TEAM=ABCDE12345 \
./build-ios.sh
```

Find your team ID with `security find-identity -v -p codesigning`.

### Knobs

All configuration is environment variables:

| Variable | Default | What it does |
|---|---|---|
| `TARGET` | `device` | `device` or `simulator`. Simulator skips signing and packaging. |
| `OSM_SRC` | *(clones)* | Path to an existing OSM checkout. Cloned into `BUILD_DIR` if unset. |
| `OSM_REF` | `v1.5.2` | Tag/branch to clone. Ignored when `OSM_SRC` is set. |
| `QMAKE` | *(autodetected)* | Path to the Qt-for-iOS `qmake`. Searched under `~/Qt/*/ios/bin`, `/usr/local/Qt/*/ios/bin`, `/opt/Qt/*/ios/bin`. |
| `BUILD_DIR` | `./build-osm-ios` | Where everything lands. |
| `CONFIGURATION` | `Release` | `Release` or `Debug`. |
| `BUNDLE_ID` | *(upstream)* | Override `com.opensoundmeter.OpenSoundMeter`. Needed if you can't sign the original. |
| `DEVELOPMENT_TEAM` | *(none)* | 10-character Apple Developer team ID. |
| `CODE_SIGN_IDENTITY` | `Apple Development` | Identity used for the post-injection re-sign. |
| `IOS_MIN` | `12.0` | Deployment target. Must match `QMAKE_IOS_DEPLOYMENT_TARGET` in the `.pro`. |

## Verification

| Test | How | Expected |
|------|-----|----------|
| Wrong platform | Run on Linux | Exits immediately with the macOS-only explanation. |
| Desktop Qt supplied | `QMAKE=~/Qt/5.15.2/clang_64/bin/qmake ./build-ios.sh` | Fails at preflight: no `macx-ios-clang` mkspec. |
| Qt too old | Qt < 5.15 on `QMAKE` | Fails at preflight before any build work. |
| Metal library built | after a run | `build-osm-ios/lib.metallib` exists and is non-empty. |
| **Metal library installed** | `ls "$APP/lib.metallib"` | Present **at the bundle root**, not under `Contents/Resources`. This is the step that decides whether charts render. |
| Signature intact | `codesign --verify --verbose "$APP"` | `valid on disk`, `satisfies its Designated Requirement`. |
| Charts actually render | Launch, add a measurement, open the RTA/Magnitude plot | Curves draw. A blank plot area means `lib.metallib` was not found — check the bundle root. |
| Microphone prompt | First launch | iOS prompts with "Audio measurement." If it never prompts, `NSMicrophoneUsageDescription` didn't make it into the built `Info.plist`. |

## Notes

- **The script is untested on macOS.** It was written on Linux by reading
  `OpenSoundMeter.pro`, `seriesnode.mm`, and the iOS plugin sources; no Mac was
  available to execute it. The logic follows directly from those sources, but
  treat the first run as a debugging session, not a turnkey build. The
  simulator path (`TARGET=simulator`) is the cheapest way to shake it out.

- **App icon is missing upstream.** The `.pro` does
  `ios_icon.files = $$files($$PWD/icons/ios/*.png)`, but `icons/ios/` **does not
  exist** in the repository — only `icons/` with desktop `.icns`/`.ico`/`.png`
  assets. The glob expands to nothing, so the app installs with a blank icon.
  To fix, generate an iOS icon set into `icons/ios/` before building, or add a
  proper asset catalog via `QMAKE_ASSET_CATALOGS`. Cosmetic only; it does not
  affect the build.

- **Simulator builds can't measure.** No real audio input, so device lists come
  back empty or synthetic. Use the simulator to confirm the UI and Metal charts
  render, then move to hardware for anything acoustic.

- **`-std=ios-metal1.0`** is what the `.pro` specifies. Recent Xcode toolchains
  warn that it's deprecated but still accept it. If a future Xcode drops it,
  bump to `ios-metal2.0` in both `build-ios.sh` and the `.pro`.

- **Free developer accounts expire in 7 days.** For anything longer-lived you
  need a paid account, and TestFlight if you want it on someone else's device.

- **Metal-capable hardware.** `SeriesNode::chooseRhi()` requires
  `MTLGPUFamilyApple3` (A9 / iPhone 6s and newer) and checks it under
  `@available(ios 13.0)`. The declared floor is iOS 12.0, but the Metal path
  effectively wants iOS 13+; older devices fall through to the OpenGL branch,
  which this build doesn't compile.

- **Version string.** The `.pro` derives `APP_GIT_VERSION` from
  `git describe --tags`. A shallow clone without tags bakes in an empty version.
  The script warns when it detects this; fix with
  `git fetch --tags --unshallow`.
