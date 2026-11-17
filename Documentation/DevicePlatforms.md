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

## Recording and physical iOS lock

Physical devices advertising `com.apple.coredevice.feature.screenrecording` use native
`devicectl device capture screen-record` first. Devices without that capability use the
preview's existing USB sample buffers or Mirror HEVC stream, written as a video-only MP4
on the Mac. Appearance support or an OS version alone does not establish recording support. Simulator
recording always uses `simctl io recordVideo`, independently of its settings backend.
Screenshot-only connections do not offer recording. Stopping or switching the preview
finalizes the current movie; stream errors, dropped compressed frames or format changes
stop recording and report the failure, preserving any playable prefix.

Physical iOS lock uses a 100 ms Consumer/Power press (page `0x0C`, usage `0x30`),
verified on iPhone 16 / iOS 26.5. The old 500 ms hold invoked Siri instead of locking.
Presses release their key even when the hold is cancelled.

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

Active or previously used available iOS and iPadOS simulators join the shared device list
with `platform: ios`, `connection: simulator` and a `simulator:<UDID>` identifier, so plugins and automation see
an iOS device. `simulator.py` lists them with `xcrun simctl list devices available -j`, at most
every three seconds; a few consecutive `simctl` failures are tolerated before simulators are
removed from the list. Never-used shut-down devices are hidden; usage is detected from
`lastUsedAt` / `lastBootedAt` in the listing or the device's `device.plist`. Starting one in
Simulator or Xcode makes it discoverable. Deleted simulators are removed on the next
successful discovery. Only booted simulators are `ready`; previously used shut-down
simulators remain in the sidebar's Available section with `state: disconnected` and their
`simulatorState`. No pairing,
Developer Mode or disk image applies. The shared window shows a device illustration,
name, OS version and Start button. Starting runs `simctl bootstatus <UDID> -b` with a
three-minute deadline and continues into the preview as discovery reports readiness.
Failures offer Retry. Cancel or changing selection stops the waiter and prevents a late
completion from opening a preview; it does not shut down the simulator. Discovery and
selection never boot a simulator, and shutting down an existing preview requires another
explicit Start. The
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
When Xcode offers `devicectl device orientation`, the simulator controls include left/right
90° rotation. Following DeviceHub, the primary toolbar button rotates Duo right and other
simulators left, with the matching directional icon. Both directions remain available in
the button's context menu and the compact device menu, with the primary direction first.
The session queries the initial physical orientation and uses the command's
reported orientation after each turn. Duo uses DeviceHub's `orientation-picker-control`
vendor report to update the virtual motion sensor; a BackBoard orientation override alone is
immediately superseded by that sensor. Its presets are `portrait`, `pud`, `landscape-left`
and `landscape-right`. Core Animation rotates the native IOSurface without
per-frame pixel copies; screenshots and normalized touches use the same displayed orientation.
The Duo inner panel adds its 90° mounting correction to the physical orientation, so unfolding
from a portrait cover displays the wide inner screen with matching touch coordinates.
Landscape dimensions therefore swap in `DeviceSession.display`. Physical iOS devices retain
their native portrait coordinate convention. A rotation or fold releases held touches and
finishes any active UI recording before changing geometry. Unsupported toolchains hide the
rotation controls.

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

## App sandbox files

`DeviceFiles` in PhoneUseKit provides read-only app-container access through the existing
`DeviceCtl` runner. MCP uses this service for `list_apps`, `list_sandbox_files`, `read_sandbox_file` and
`download_sandbox_file`. These operations resolve the shared device selection without
opening a video/input session. Android is explicitly unsupported. CoreDevice must know the
device; daemon-only wireless pairing is not a fallback route for this feature.

App availability comes from `containerAccessible`, not `builtByDeveloper`. Missing access
metadata stays unknown. Directory listings are non-recursive; devicectl's entry paths are
relative to the requested directory, and the service returns container-relative paths.
Absolute paths and parent traversal are rejected. Only regular readable files can be read or
downloaded; selected symlinks and directories are rejected. UTF-8 previews are limited to
64 KiB, including a second size check after copying. Downloads stage beside the chosen local
destination, publish after a successful copy, never replace an existing destination, and
clean partial copies on failure. No device-side mutation commands are exposed.

Offline tests cover path parsing, reported permissions, preview limits, download cleanup,
MCP validation/dispatch/pagination. Read-only
integration tests can be enabled with `DEVICEHUB_SANDBOX_DEVICE`, `DEVICEHUB_SANDBOX_APP`
and `DEVICEHUB_SANDBOX_FILE`; they list the app/container and download the chosen file to
a temporary location, without launching or modifying the app.

## Apple device settings

The app's settings panel uses `DeviceSettings`, which picks one settings route per
iPhone, iPad or simulator; Android has none yet. Recording chooses its transport separately.

- **Xcode (`devicectl`)**, when `devicectl help device settings appearance` lists the
  accessibility options (Xcode 27). It covers interface style, Liquid Glass, color filters, text
  size, Increase Contrast, Reduce Motion, Reduce Transparency, Show Borders, VoiceOver, audio
  routing and volume, and location scenarios; changes persist on the device.
  A physical device is used only if `devicectl device info appearance` answers for it, since
  CoreDevice may not know a device that only the daemon paired.
- **Device services**, for physical devices otherwise. The worker holds one
  `com.apple.accessibility.axAuditDaemon` channel (Increase Contrast, Reduce Motion, Reduce
  Transparency, Button Shapes shown as Show Borders, Grayscale, text size on a 0–1 slider over
  all twelve sizes) and one DVT `LocationSimulation` channel per fixed coordinate. The device
  keeps both only while their channel is open, so changes revert when the worker closes.
- **`simctl`**, for simulators on an older Xcode: `ui` appearance, Increase Contrast and content
  size, `location`, and `io recordVideo`.

Dual-screen simulators expose closed (0°), partially open (90°), and flat (180°) controls in
both apps through `DeviceSession.setPosture`. This follows Xcode DeviceHub's Pop plugin:
`IndigoVendorDefinedEvent`, vendor usage `0xFF61/0x5B`, carries an IOCF-serialized hinge command
on the simulator's dedicated vendor HID channel. It requires Xcode's modern DTUHID service.
The preview observes both framebuffers and selects the commanded panel (cover when closed,
inner otherwise), because this runtime can leave backlight metadata pointing at the cover.
Touch events carry that panel's screen ID; screenshots and recording use its display UUID.
Input pauses while SpringBoard settles the hinge, and changing posture finalizes any recording.
This provides screen controls, not DeviceHub's 3D chassis animation. `DEVICEHUB_FOLDABLE_SIMULATOR_UDID`
enables the integration test that exercises all three postures on a booted Duo.

Device rotation still has no supported control here: `devicectl device orientation set`
reports success on an iOS 27 simulator but leaves the orientation unchanged.

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

### Finder sandbox volumes

PhoneUse's toolbar More menu exposes “应用沙箱…”, which opens the shared `DeviceFilesPanel`
app picker, then opens
an actual Finder volume instead of embedding a custom file browser. `DeviceSandboxVolumes`
calls the daemon's `mountSandbox`, `sandboxMounts` and `unmountSandbox` RPCs. Only physical
iOS devices are supported. Listing/ejecting mounts does not create a worker; mounting reuses
the device worker's RSD connection and opens House Arrest for the selected app. It requires
no screen/video session. The app list still comes from CoreDevice; its reported access flag
is a hint, while House Arrest determines whether the container can actually be mounted.

`sandbox_mounts.py` serves AFC through pymobiledevice3's existing WebDAV dependencies on
an ephemeral loopback port. Each volume has a random URL prefix; RPC replies expose only
mount ID, bundle ID and local path. The provider and macOS mount are read-only, and an ASGI
guard rejects writes, traversal, unknown URL prefixes and recursive PROPFIND requests.
`mount_webdav -S` enables system-managed cleanup when the server disappears. A worker
watcher closes the file service after Finder ejects the volume; normal worker shutdown also
unmounts volumes before closing the tunnel. A busy explicit eject keeps the server alive so
users can close files and retry. No Samba, FUSE, device-side agent or additional daemon is
installed. Finder may cache data; eject/remount to refresh files changed by the running app.

Tests cover the HTTP guard, mount reuse/failure/cancellation/shutdown, Finder eject detection,
RPC routing and late UI results after dismissing/changing devices. The Python opt-in test
uses the same `DEVICEHUB_SANDBOX_DEVICE`, `DEVICEHUB_SANDBOX_APP`, `DEVICEHUB_SANDBOX_FILE`
variables to mount through RSD, list/read a real file, check the filesystem read-only flag,
and unmount. Run it with `PYTHONPATH=Daemon .venv-daemon/bin/python -m unittest discover
-s Daemon/tests -p test_sandbox_mounts.py -v`.

The picker loads real PNG app icons through `appIcon` and SpringBoard's `getIconPNGData`
over the same RSD connection. Requests are serialized, bounded to 512 KiB per icon, and
cached in worker memory by bundle ID/version (up to 128 entries). Rows load asynchronously
and use a placeholder on failure; missing icons do not block app selection or mounting.
