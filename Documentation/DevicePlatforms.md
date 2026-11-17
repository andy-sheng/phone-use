# Device platform boundaries

phone-use (app, CLI, MCP server) and automation (app, `automation-bridge`) both use
`DeviceSession` from PhoneUseKit. Each app runs its own daemon, chosen by `PhoneUseConfiguration`. Platform selection
occurs when the session opens; each session owns one `DeviceConnection` implementation.

| Layer | Shared contract | iOS implementation | Android implementation |
| --- | --- | --- | --- |
| Control | `DeviceConnection` | `Platforms/iOS/IOSDeviceConnection.swift`: RemoteXPC services and HID | `Platforms/Android/AndroidDeviceConnection.swift`: Android daemon RPC |
| Preview | `ScreenStream` | `ScreenStreams/iOS`: HEVC Mirror and CoreMediaIO USB capture | `ScreenStreams/Android`: scrcpy framing, H.264 decoding and video lifetime |
| Fallback | Screenshot surface | Provider permits video retries | Provider reports the video failure and offers an explicit reconnect |
| Daemon worker | Supervisor routing and worker lifecycle | Apple device worker | scrcpy control-only input channel plus a separate scrcpy video manager |

`DeviceSession` does not construct Apple HID or service messages. The Android adapter
never calls Apple services. The screen model does not choose a codec or operate ADB,
CoreMediaIO or a video socket. Providers own platform-specific preparation and recovery
policy. In particular, selecting Android does not trigger Apple USB re-enumeration.

## Preview connections

Selecting or discovering a device shows an idle device frame with a central
Connect button. `ScreenModel` requires an explicit request for that device before
calling the platform's preparation provider or opening a `DeviceSession`.
Changing selection clears the request, including when switching back to a
previous device. A transient readiness/link change on the same device retains
an existing request so USB screen-capture re-enumeration can finish normally.

The connection placeholder shows progress and Cancel while opening, and Retry
after a failed attempt. Each view task has a generation so a late result from a
cancelled or replaced attempt cannot overwrite the new selection's state.
Preview cancellation stops its stream without closing shared daemon workers
used by automation, CLI or MCP. Their explicit session-opening behavior stays
independent of the preview's Connect button.

`PhoneUseUITests` exercises selection without transport side effects, explicit
retry, cancellation and late completion; it is included in `swift test`.

## iOS nearby pairing

`wireless_pairing.py` owns explicit, three-minute discovery and pairing sessions.
It browses `_remotepairing-manual-pairing._tcp` without requiring an existing pair
record, and advertises `_remotepairing-pairable-host._tcp` for iOS/iPadOS 27's
device-initiated flow in Settings > Developer > Paired Macs. The host listens on
one dual-stack port. The app displays the setup code through a callback; the
daemon never prompts on stdin or prints the code to stdout or logs.

The local RPC methods are `startWirelessPairing`, `wirelessPairingStatus`,
`pairNearbyDevice` and `stopWirelessPairing`. Status and actions require both the
session ID and its owning socket connection. A stale stop request cannot close
a replacement session. Closing the sheet, losing its RPC connection, expiry or
daemon shutdown cancels discovery and handshakes, closes peer sockets, and
withdraws the advertisement. Only a successful authenticated pairing persists
a pair record and joins the normal shared device list; browsing alone never
makes an unknown device ready. Xcode's pairing keys are not imported.

Normal Wi-Fi discovery combines system `usbmuxd` devices with connection type
`Network` and `_remotepairing._tcp` advertisements matching the library's pair
records. System connections work even when this tool has never created a remote
pair record: their name, OS version and readiness come from trusted network
lockdown, and the worker opens `CoreDeviceProxy` over that same network link.
The system trust stays in the system; this path neither imports Xcode keys nor
performs a new pairing. USB keeps priority when both links are present.

Bonjour browsing (RemotePairing discovery, connection and nearby pairing) goes
through the system mDNSResponder (`dns_sd`), not pymobiledevice3's own UDP 5353
sockets: when a VPN or TUN proxy owns the multicast route, raw queries leave
through the tunnel and no device answers. Sleeping iPhones drop out of both
Bonjour and the `usbmuxd` list while staying reachable, so the daemon keeps
`usbmuxd` sightings for 90 s and RemotePairing sightings for 30 s, renews a quiet
RemotePairing peer with a plain TCP connect to its last advertised address, and
hands those addresses to the worker to try before a fresh browse. A device with
an open Wi-Fi session stays attached while its worker's tunnel is alive.
A first connection without USB obtains its actual OS version from the worker
before selecting mirror video and the iOS 27 HID authentication policy.

Offline tests cover discovery without prior records, address fallback without
replaying consent, failed code verification, cancellation, timeout, client
ownership, and USB session preservation. They do not establish physical-device
pairing, local network permission attribution, or Wi-Fi video/input acceptance.

## Android input ownership

PhoneUseKit does not use MaaFramework. Each Android worker starts a private scrcpy 3.3.4
server with `video=false` and `control=true` (`android_control.py`) when the device opens,
and keeps that one control socket for the worker's life. Without video, scrcpy injects
positional events at raw display coordinates of display 0, so the worker sends native
screenshot pixels. Touches use scrcpy's generic-finger pointer; taps hold for 50 ms and swipes
are interpolated down/move/up sequences. Keys send down and up keycode events. Injection is
not acknowledged, so the worker still verifies input permission (`input keyevent 0`) before
the first input and checks display geometry before every coordinate-bearing event. A channel
that ends is restarted on the next input; a failed lift still frees the held touch. The
control server is announced and cleaned up exactly like the video server: its own forward,
temporary jar and PID, killed only while it carries the worker's private marker.

Screenshots use `adb exec-out screencap` (raw RGBA/BGRA, 12- or 16-byte header) encoded as
PNG on the Mac; app launches use `monkey` for packages and `am start -n` for activities, so
neither needs input permission.

Sessions of the same app share the worker. Every touch request carries its session's `owner`.
A held touch can only be moved or lifted by the session that pressed it, so closing the
preview, or a rejected preview gesture, never lifts a finger held by another session. Rotation
and worker shutdown still release input unconditionally.

automation's Android tasks do not go through this worker: MaaFramework's own `AdbController`
(MaaTouch/minitouch) drives the device, on the adb executable the daemon reports through the
`androidTools` RPC so the two never restart each other's adb server. While a task runs on a
device, automation's preview is view-only and its input view lifts any held touch.

Coordinate-bearing input checks the live default-display viewport from `dumpsys input`
instead of taking a screenshot before each touch sample. Some phones take over a second
to capture a frame, which delays clicks and turns continuous drags into long presses.
The metadata check validates dimensions and rotation against the opened session,
including 180-degree turns. A failed check rejects input and releases that owner's
contact; it never guesses an orientation or replays the gesture. Screenshots remain
native-resolution operations for preview fallback and automation recognition.

## iOS Simulator

Booted iOS and iPadOS simulators join the shared device list with `platform: ios`,
`connection: simulator` and a `simulator:<UDID>` identifier, so plugins and automation see
an iOS device. `simulator.py` lists them with `xcrun simctl list devices booted -j`, at most
every three seconds; a few consecutive `simctl` failures are tolerated before simulators are
detached. They are always `ready`: no pairing, Developer Mode or disk image applies. The
daemon starts no worker for them, acknowledges `openDevice` without one, and rejects Apple
device services, mirroring and Android RPC for simulator identifiers.

`DeviceSession` drives a simulator in its own process through
`Platforms/Simulator`. `CoreSimulatorBridge` loads Xcode's CoreSimulator and SimulatorKit at
runtime (from `DEVELOPER_DIR`, `xcode-select -p`, or `/Applications/Xcode.app`) and is the
only code that touches their private interfaces. On CoreSimulator 1155.4 and later, touches,
buttons and keyboard events use a persistent XPC connection to the simulator's DTUHID digitizer
service, with a bounded liveness round trip before accepting input. A lookup or send callback
alone is insufficient: modern guests can silently drop the legacy Indigo channel. Older
CoreSimulator versions use `SimDeviceLegacyHIDClient` with the Indigo messages Simulator.app builds: single-finger mouse
events on the touchscreen target, Home and side-button event sources, and consumer-page usages
for volume and Siri. Back and app switch remain Android-only. Apps launch with
`simctl launch --terminate-running-process`.

The preview layer shows the main display's framebuffer IOSurface and refreshes on each damage
report. CoreSimulator returns remote proxies that marshal callback arguments from the block's
type encoding, so the damage block takes an object. A headless simulator may not update the
surface while nobody observes it; screenshots read the surface only after the session's own
registration has seen a redraw, and otherwise capture with `simctl io screenshot`.
Coordinates are normalized to the portrait framebuffer, as on physical iOS devices.

`DeviceSession.uiTree`, `activate` and `typeText` provide simulator accessibility and US-keyboard
input. The AXP translator runs on a serial background queue with bounded callbacks and traversal;
selectors are resolved fresh and ambiguous matches fail. AX frames are UI points, distinct from
the native portrait screenshot coordinates. Element activation uses AX rather than guessing a
rotation transform. Text input validates the complete string before activation, releases keys on
failure and never replays partial input. The physical iOS adapter forwards hierarchy and selector
operations to `ios_ui.py` through the existing daemon. A bounded, serialized AX Audit session reads
`_AXHierarchyElementsAttribute` without focus walking; selectors are resolved and activated on the
same DTX connection. Inspector cleanup runs on success, failure and cancellation independently of
the persistent settings channel. Only development-signed foreground apps expose this hierarchy.
Physical trees omit unavailable geometry and value, and enabled state may be unknown. Truncated
trees cannot be used for selector actions. On iOS 27+, `ios_keyboard.py` supplies a temporary virtual
HID keyboard authenticated by the worker's existing media stream; partial input is never replayed.
Android still reports these capabilities as unavailable. The MCP contract and compatibility details are in [MCP.md](MCP.md).

Release builds keep library validation; both frameworks are signed by Apple (`anchor apple`).
Offline tests cover discovery parsing, supervisor routing and input mapping;
`DEVICEHUB_SIMULATOR_UDID` enables a read-only display and screenshot check against a booted
simulator. Touch delivery and the live preview were checked by hand on an iOS 27 simulator.

## Apple device settings

The app's settings panel and screen recording use `DeviceSettings`, which picks one route per
iPhone, iPad or simulator; Android has none yet.

- **Xcode (`devicectl`)**, when `devicectl help device settings appearance` lists the
  accessibility options (Xcode 27). It covers interface style, Liquid Glass, color filters, text
  size, Increase Contrast, Reduce Motion, Reduce Transparency, Show Borders, VoiceOver, audio
  routing and volume, location scenarios and screen recording, and changes persist on the device.
  A physical device is used only if `devicectl device info appearance` answers for it, since
  CoreDevice may not know a device that only the daemon paired.
- **Device services**, for physical devices otherwise. The worker holds one
  `com.apple.accessibility.axAuditDaemon` channel (Increase Contrast, Reduce Motion, Reduce
  Transparency, Button Shapes shown as Show Borders, Grayscale, text size on a 0–1 slider over
  all twelve sizes) and one DVT `LocationSimulation` channel per fixed coordinate. The device
  keeps both only while their channel is open, so changes revert when the worker closes.
- **`simctl`**, for simulators on an older Xcode: `ui` appearance, Increase Contrast and content
  size, `location`, and `io recordVideo`.

Device rotation and foldable display postures have no command-line interface: `devicectl device
orientation set` reports success on an iOS 27 simulator but leaves the orientation unchanged.

## ADB selection

`DEVICEHUB_ADB` wins when set. Otherwise the daemon prefers a user-installed adb (PATH,
Android SDK, Homebrew) and uses the copy bundled under `DEVICEHUB_ANDROID_ASSETS` only as
a fallback: adb clients restart a server of a different version, so a bundled adb that
differs from Android Studio's would keep dropping every device connection. ADB discovery
tolerates a few consecutive failures before treating Android devices as detached.
In development, `.build/android/platform-tools/adb` is the final fallback when no
bundled assets directory is configured. `setup-dev.sh` prepares this standalone copy;
Android Studio and PATH changes are not required.

## Android video

The pinned scrcpy server captures H.264 on the device. ADB forwards its socket to a
daemon-owned relay on `127.0.0.1`. The Swift Android stream consumes framed packets and
feeds an `AVSampleBufferDisplayLayer`; screenshots are not used to simulate video.
The video server has audio and control disabled; input belongs to the worker's separate
control channel. Screenshots for recognition remain native-resolution captures, so video
scaling does not change automation coordinates.

`startAndroidVideo` returns `{port, token}`. The consumer writes the token followed by
a newline before receiving scrcpy metadata and packets. `stopAndroidVideo` includes
the same token, so cleanup from an old preview cannot stop a newer one. The relay
accepts one authenticated consumer and cleans up its server, forward and temporary
device file when that consumer disconnects. An unused endpoint also expires.

The Swift stream succeeds only after VideoToolbox has decoded its first keyframe into
an image buffer. This also works before the UI attaches the display layer to a window.
Startup failure reports the cause and falls back to screenshot polling. Failure after
startup is reported through the shared stream error callback; the UI offers reconnect.
Stopping video does not close the input channel or release another session's
gesture. Closing the device worker closes both its control and video resources.

Packet sizes, startup waits and transport backpressure are bounded. Malformed data
fails the stream. SPS/PPS changes reset the H.264 format; a changed display aspect
ratio stops the preview to avoid sending coordinates for a stale orientation. Native
screenshot geometry checks validate captures, while live display metadata checks protect
input even when a rotation preserves the dimensions.

## Dependencies and checks

`scripts/android-assets.json` pins both the official macOS Platform-Tools ZIP and the
scrcpy server, with upstream URLs, checksums and license provenance.
`scripts/setup-dev.sh` invokes `prepare-android-tools.py --download` and
`prepare-android-video.py --download` explicitly. Verified downloads and extracted
files are reused under `.build/android/`; `--archive` can prepare ADB from the same
pinned ZIP without network access. Both the ZIP and extracted ADB, runtime library,
upstream `NOTICE.txt` and `source.properties` are checked against pinned SHA-256s.

`build-app.sh` checks Android assets before starting Xcode. Release embedding stays
offline and copies only ADB, its runtime library and upstream notices, then signs the
Mach-O files. The default build uses the prepared pinned copy rather than whichever
SDK happens to be installed. An explicit `DEVICEHUB_ADB` preserves the custom-tool
build override (including its adjacent library and notice files); this override is
outside the pinned asset checks. Runtime ADB selection still prefers the user's SDK
to avoid restarting an existing ADB server with a different version.

Daemon tests cover routing, authentication, timeouts and cleanup. Swift tests cover
framing, H.264 configuration, geometry and stream cancellation. Hardware checks are
kept separate so offline regression tests never inject input into a connected phone.
