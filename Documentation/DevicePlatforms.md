# Device platform boundaries

The app, CLI, MCP server and automation bridge share `DeviceSession`. Platform selection
occurs when the session opens; each session owns one `DeviceConnection` implementation.

| Layer | Shared contract | iOS implementation | Android implementation |
| --- | --- | --- | --- |
| Control | `DeviceConnection` | `Platforms/iOS/IOSDeviceConnection.swift`: RemoteXPC services and HID | `Platforms/Android/AndroidDeviceConnection.swift`: Android daemon RPC |
| Preview | `ScreenStream` | `ScreenStreams/iOS`: HEVC Mirror and CoreMediaIO USB capture | `ScreenStreams/Android`: scrcpy framing, H.264 decoding and video lifetime |
| Fallback | Screenshot surface | Provider permits video retries | Provider reports the video failure and offers an explicit reconnect |
| Daemon worker | Supervisor routing and worker lifecycle | Apple device worker | Maa input worker plus a separate scrcpy video manager |

`DeviceSession` does not construct Apple HID or service messages. The Android adapter
never calls Apple services. The screen model does not choose a codec or operate ADB,
CoreMediaIO or a video socket. Providers own platform-specific preparation and recovery
policy. In particular, selecting Android does not trigger Apple USB re-enumeration.

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
A first connection without USB obtains its actual OS version from the worker
before selecting mirror video and the iOS 27 HID authentication policy.

Offline tests cover discovery without prior records, address fallback without
replaying consent, failed code verification, cancellation, timeout, client
ownership, and USB session preservation. They do not establish physical-device
pairing, local network permission attribution, or Wi-Fi video/input acceptance.

## Android input ownership

The preview and an automation run open separate sessions on the same Android worker and
its single Maa controller. Every touch request carries its session's `owner`. A held touch
can only be moved or lifted by the session that pressed it, so closing the preview, or a
rejected preview gesture, never lifts a finger held by automation. Rotation and worker
shutdown still release input unconditionally.

## ADB selection

`DEVICEHUB_ADB` wins when set. Otherwise the daemon prefers a user-installed adb (PATH,
Android SDK, Homebrew) and uses the copy bundled under `DEVICEHUB_ANDROID_ASSETS` only as
a fallback: adb clients restart a server of a different version, so a bundled adb that
differs from Android Studio's would keep dropping every device connection. ADB discovery
tolerates a few consecutive failures before treating Android devices as detached.

## Android video

The pinned scrcpy server captures H.264 on the device. ADB forwards its socket to a
daemon-owned relay on `127.0.0.1`. The Swift Android stream consumes framed packets and
feeds an `AVSampleBufferDisplayLayer`; screenshots are not used to simulate video.
The video server has audio and control disabled. Maa remains the input owner, and
automation continues to request native-resolution screenshots through the control
adapter for recognition. Video scaling does not change automation coordinates.

`startAndroidVideo` returns `{port, token}`. The consumer writes the token followed by
a newline before receiving scrcpy metadata and packets. `stopAndroidVideo` includes
the same token, so cleanup from an old preview cannot stop a newer one. The relay
accepts one authenticated consumer and cleans up its server, forward and temporary
device file when that consumer disconnects. An unused endpoint also expires.

The Swift stream succeeds only after VideoToolbox has decoded its first keyframe into
an image buffer. This also works before the UI attaches the display layer to a window.
Startup failure reports the cause and falls back to screenshot polling. Failure after
startup is reported through the shared stream error callback; the UI offers reconnect.
Stopping video does not close the shared Maa controller or release an automation
gesture. Closing the device worker closes both its control and video resources.

Packet sizes, startup waits and transport backpressure are bounded. Malformed data
fails the stream. SPS/PPS changes reset the H.264 format; a changed display aspect
ratio stops the preview to avoid sending coordinates for a stale orientation. Native
screenshot geometry checks continue to protect input. Fixed-coordinate tasks should
lock orientation because a 180-degree rotation may preserve the dimensions.

## Dependencies and checks

`scripts/android-assets.json` pins the upstream server version and checksums.
`scripts/prepare-android-video.py` prepares the development cache explicitly; release
embedding verifies and copies cached assets without silently downloading them.

Daemon tests cover routing, authentication, timeouts and cleanup. Swift tests cover
framing, H.264 configuration, geometry and stream cancellation. Hardware checks are
kept separate so offline regression tests never inject input into a connected phone.
