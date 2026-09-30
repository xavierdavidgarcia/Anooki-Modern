# Anooki — modern macOS screensaver

A rebuild of the 2013 Anooki screensaver so it runs on modern macOS
(Big Sur 11.0 through Tahoe 26 and later). The original 32-bit Flash-based
bundle is incompatible with anything from Catalina onwards.

## How it works

The original bundle's Flash animations (`anims/anim0.swf` … `anim29.swf`,
`animEND.swf`) are reused untouched. The modern shell is a native Swift
`ScreenSaverView` that hosts a `WKWebView` running [Ruffle], a Rust/WASM
Flash emulator. The HTML host (`Resources/player.js`) shuffles through the
animations and plays them one after another, just like the original engine.

[Ruffle]: https://ruffle.rs

```
Anooki.saver
└── Contents
    ├── Info.plist
    ├── MacOS/Anooki          ← universal Swift bundle (arm64 + x86_64)
    └── Resources
        ├── index.html        ← Ruffle host page
        ├── player.js         ← animation rotation logic
        ├── anims/anim*.swf   ← original 2013 animations (untouched)
        └── ruffle/           ← bundled Ruffle (self-hosted, WASM + JS)
```

## Build

You need Xcode command-line tools. Install once:

```sh
xcode-select --install
```

Then from this directory:

```sh
./scripts/fetch-ruffle.sh   # one time, or any time to update Ruffle
./build.sh                  # produces build/Anooki.saver
```

The build script:

1. Compiles `src/AnookiSaverView.swift` for arm64 and x86_64
2. `lipo`s them into a universal Mach-O **bundle** (the format a `.saver` requires)
3. Lays out the `.saver` directory and copies all resources
4. Strips extended attributes inherited from the 2013 SWFs
5. Code-signs (see below)

## macOS 26 Tahoe: Developer ID is mandatory

Apple enforces a **kernel-level launch constraint** on macOS 14+ (and
much harder on macOS 26 Tahoe): `ScreenSaverEngine` will `SIGKILL`
any `.saver` that is not signed with a Developer ID *and* notarized.
Ad-hoc signing produces a "Launch Constraint Violation" crash before
your code runs. There is no user-level override.

### One-time setup

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll/)
   ($99/yr).
2. In Xcode → Settings → Accounts → your account → **Manage Certificates**,
   click `+` and choose **Developer ID Application**. (Or generate one
   via the developer portal and import it.)
3. Find your identity string:
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   It looks like: `"Developer ID Application: Your Name (ABC123XYZ)"`.
4. Generate an [app-specific password](https://account.apple.com/account/manage)
   for the notary service.
5. Store credentials in the keychain so `notarytool` can find them:
   ```sh
   xcrun notarytool store-credentials anooki-notary \
       --apple-id "you@example.com" \
       --team-id  "ABC123XYZ" \
       --password "xxxx-xxxx-xxxx-xxxx"
   ```
   (`anooki-notary` is just a label you'll reuse below.)

### Build, sign, notarize, install

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (ABC123XYZ)" \
NOTARY_PROFILE=anooki-notary \
    ./build.sh
```

The script signs with the hardened runtime + your entitlements, zips,
uploads to the Apple notary service, waits for the result (1–10 min
typically), and staples the ticket. The resulting `build/Anooki.saver`
will pass Gatekeeper and load cleanly in System Settings → Screen Saver.

## Install

Either double-click `build/Anooki.saver` and confirm the System Settings
prompt, or copy it manually:

```sh
cp -R build/Anooki.saver ~/Library/Screen\ Savers/
```

Then open **System Settings → Screen Saver**, scroll down past Apple's
built-in screensavers, and pick **Anooki**.

### Gatekeeper note

If you signed and notarized properly, no extra steps. The first time
macOS sees the saver it may pause briefly to verify the staple ticket.

If you skipped notarization (or used ad-hoc for testing) Tahoe will
SIGKILL the bundle inside ScreenSaverEngine and you'll see a crash
report at `~/Library/Logs/DiagnosticReports/ScreenSaverEngine-*.ips`
with `indicator: Launch Constraint Violation`.

## Updating Ruffle

Ruffle ships nightly builds and its Flash-emulation accuracy keeps
improving. Run `./scripts/fetch-ruffle.sh` followed by `./build.sh`
to pick up a newer version.

## Known limitations / troubleshooting

- **Audio.** Ruffle in a screensaver may render the animations silently
  because macOS suppresses autoplay audio in WebView contexts without a
  user gesture. The visuals are unaffected.
- **Animation fidelity.** Ruffle's ActionScript 3 support is excellent
  but not pixel-perfect for every SWF. If a particular anim glitches,
  open an issue with [Ruffle] — bug reports help them. The hard timeout
  in `player.js` (30s) ensures a broken anim doesn't freeze the saver.
- **Black screen on first launch.** macOS sometimes refuses to launch a
  freshly installed `.saver` until you reopen System Settings. Quit
  System Settings and reopen; or log out and back in.
- **Verifying it works.** You can preview without setting it as your
  active screensaver: System Settings → Screen Saver → click Anooki →
  **Preview**.
- **Performance.** Each anim is 200–400KB SWF decoded by Ruffle in
  WASM. Should be fine on any 2015+ Mac. If you see stutter on an old
  Mac, drop the `animationTimeInterval` in `AnookiSaverView.swift`.

## File map

| Path                     | Purpose                                  |
|--------------------------|------------------------------------------|
| `src/AnookiSaverView.swift` | The `ScreenSaverView` subclass.       |
| `src/Info.plist`         | Bundle plist (`NSPrincipalClass`, ID).   |
| `Resources/index.html`   | Page loaded into the WebView.            |
| `Resources/player.js`    | Picks a random anim and plays it.        |
| `Resources/anims/`       | Original 31 Flash animations.            |
| `Resources/ruffle/`      | Ruffle self-hosted distribution.         |
| `scripts/fetch-ruffle.sh` | Downloads latest Ruffle nightly.        |
| `build.sh`               | Compiles + packages `Anooki.saver`.      |

## Credits

- Original Anooki characters and animations © their authors (Mickey Wing
  Co., Pierre & Maïté Anooki). Not affiliated with this rebuild.
- Original Flash screensaver wrapper: Screentime Screensaver Factory
  (2012, no longer maintained).
- Flash emulation: Ruffle (https://ruffle.rs), Apache-2.0 / MIT.
- Modern shell: written 2026.
