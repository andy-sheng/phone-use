# Duo posture icons

These template images are rendered from the custom Duo symbols in Xcode 27.1
(27A9273), as used by DeviceHub:

`DeviceKit.framework/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/Assets.car`

| Asset | Original symbol |
| --- | --- |
| DuoClosed | v68_Closed |
| DuoHalfOpen | v68_HalfOpen_Landscape |
| DuoOpen | v68_Open |
| DeviceRotateLeft | rotate.device.left |
| DeviceRotateRight | rotate.device.right |

Rendered with AppKit at 15 pt, medium weight, monochrome, centered in a transparent
24 pt square at 1×, 2× and 3×. Template rendering preserves the selected accent color
and the normal/disabled foreground colors. Resources are bundled locally so the
buttons do not depend on an installed Xcode or its private symbols at runtime.

Original artwork belongs to Apple; these assets are not covered by the repository's
own source-code license.
