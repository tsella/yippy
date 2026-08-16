# Yippy! — Xiaomi Yi Action Camera Controller

iOS/SwiftUI replacement for the discontinued official Xiaomi Yi action camera app.
Talks to the camera over its Ambarella JSON-over-TCP control protocol, RTSP for
live view, and plain HTTP for media download.

## Hardware & network facts

The camera is a **Xiaomi Yi Action Camera** (Ambarella A7LS chipset). When its
Wi-Fi is enabled it becomes an access point; the phone must join that network.

| What | Where |
| --- | --- |
| SSID prefix | `YDXJ_` (default password `1234567890`) |
| Camera IP | `192.168.42.1` (phone gets `192.168.42.x` via DHCP) |
| Control channel | TCP **7878**, newline-delimited JSON |
| Live view | `rtsp://192.168.42.1/live` (port 554) |
| Media download | `http://192.168.42.1/<path relative to /tmp/fuse_d/>` |
| SD card path | `/tmp/fuse_d/DCIM/100MEDIA` |

**The camera's network has no internet.** iOS will happily route sockets over
cellular instead, which fails with `EADDRNOTAVAIL (49)`. Every connection must
pin `NWParameters.requiredInterfaceType = .wifi`. Do not remove that.

**Testing requires real hardware.** The Simulator cannot join the camera's Wi-Fi,
so nothing below the UI layer can be verified on it. Protocol changes must be
tested on a physical device attached to a powered-on camera.

## Protocol

Single JSON object per message, terminated by `\n`, e.g.
`{"msg_id":769,"token":5}`. Responses echo `msg_id` and carry `rval`
(`0` = success, negative = error).

**Session flow:** send `{"msg_id":257,"token":0}` first; the reply's `param` is
the session token that every later command must include. The camera drops idle
sessions after roughly 20 minutes, so traffic must be kept flowing.

`msg_id` **259 is `AMBA_BOSS_RESETVF` — it starts the RTSP viewfinder.** It is
not a keepalive/ping. Use a cheap read such as `13` (battery) to hold the
session open.

### The RTSP stream must be started explicitly

**`rtsp://192.168.42.1/live` does not exist until `259` is sent.** The exact
request, per a packet capture of the official app, is:

```json
{"msg_id":259,"param":"none_force","token":<token>}
```

**There is no `type` field.** An earlier version of this app sent
`type:"app_status"` (copied from a settings-command example) and the stream did
not start. The capture and the one working reference implementation both omit
it. Three keys, nothing more.

**Ignore the `vf_stop` the camera sends immediately after connect.** It arrives
before `259` is ever issued, so treating it as authoritative races with
`startViewfinder()` and leaves the player permanently unmounted. The client only
honours `vf_stop` once it has actually requested the viewfinder.

Skip it and the camera emits a `vf_stop` notification and never starts its RTSP
server, so VLC fails to bind and logs:

```
Unable to determine our source address: This computer has an invalid IP address: 0.0.0.0
```

That message is a *symptom of the missing 259*, not a VLC or network bug — the
player is dialing a server that was never started. `260` stops the stream again
and re-enables the physical shutter button on some firmwares.

**live555 needs iOS Local Network permission to be *granted*.** It enumerates
local interfaces to pick an RTP source address; without the permission it gets
nothing and reports `invalid IP address: 0.0.0.0` — while the TCP control socket
to the same host works fine, which makes it look like a VLC bug. An
`NWConnection` to a literal IP does not reliably raise the prompt, so
`NSBonjourServices` is declared and a short `NWBrowser` runs on connect purely
to trigger it.

**A bad VLC option aborts the player before it exists.** `VLCMediaPlayer(options:)`
validates the whole list at library init: one unknown option or one boolean
given `=value` and `libvlc_media_player_new` fails, taking the viewfinder with
it. Boolean options take `--x` / `--no-x` (`--rtsp-http=0` is rejected;
`--no-rtsp-http` is correct), and `--ipv4` no longer exists in this build.
Verify any new option against the shipped framework before adding it:

```bash
strings Pods/MobileVLCKit/MobileVLCKit.xcframework/ios-arm64_armv7_armv7s/MobileVLCKit.framework/MobileVLCKit | grep -x '<option>'
```

The `START_SESSION` (257) response advertises the stream URL in its `rtsp`
field; prefer it over hardcoding. Track liveness via the `vf_start`/`vf_stop`
notifications and only mount the player while the viewfinder is active.

### The camera wedges if you talk to it mid-capture

**Observed on real hardware.** After `TAKE_PHOTO`, the camera emits
`start_photo_capture` and is single-threaded until the capture completes. Any
command sent in that window — including the 5-second heartbeat — kills its TCP
server: every subsequent request times out, and the camera eventually drops its
Wi-Fi entirely (`EADDRNOTAVAIL 49` / "No network route"). Only a power cycle
recovers it.

`isCapturing` gates the camera from `start_photo_capture` until `photo_taken`.
**Enforced in `sendRaw`**, so *every* request waits — gating only the shutter
and the heartbeat was not enough: the gallery's refresh-on-capture fired
`LIST_DIRECTORY` and wedged the camera anyway. A watchdog releases the gate
after 8s so a firmware that never reports completion cannot stall the app.

**`precise_capture_data_ready` is not a completion signal.** The data exists but
the camera is still writing it; treating it as "done" let the next command
through and wedged the TCP server. Only `photo_taken` (or the watchdog)
releases the gate.

`msg_id` **7 is a camera-initiated notification**, never a request. It has no
matching outstanding request, so it must not be routed through the
request/response continuation map.

All `msg_id`, `rval`, and notification `type` values live in
[`Sources/AmbarellaProtocol.swift`](Sources/AmbarellaProtocol.swift) as
`YiCommand`, `YiReturnCode`, and `YiNotification`. **Add new codes there, not as
inline magic numbers**, and log failures via `YiReturnCode.describe(rval:msgId:)`
so the code and its meaning both appear.

### Response quirks that break naive parsing

- **Directory listings (`1282`) use the filename as the JSON *key*** and pack the
  metadata into a string value:
  `{"listing":[{"YDXJ1155.mp4":"391922457 bytes|2015-05-25 14:35:18"}]}`.
  There is no `name`/`size` key to read.
- **Scalar types are inconsistent across firmwares.** Battery level and file
  sizes arrive as either `Int` or `String` depending on build. Always accept both.
- Some firmwares omit the trailing newline on responses, so the receive buffer
  cannot assume a terminator will arrive before the next parse attempt.

## Build

**Do not use XcodeGen.** The `.xcodeproj` is the source of truth and is checked
into git. `project.yml` has been deleted; regenerating the project drops the
CocoaPods integration and resets settings such as `PRODUCT_BUNDLE_IDENTIFIER`.
Add files and change settings in Xcode directly.

```bash
open YiCamera.xcworkspace
```

Always open the **`.xcworkspace`**, never the `.xcodeproj` — MobileVLCKit is a
CocoaPod and will not link otherwise. If the pods are missing from a fresh
clone, run `pod install`.

The bundle id is `la.tsel.yippy`, set as `PRODUCT_BUNDLE_IDENTIFIER` in the
target's build settings.

To verify a change compiles without a signing team:

```bash
xcodebuild -workspace YiCamera.xcworkspace -scheme YiCamera \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  build CODE_SIGNING_ALLOWED=NO
```

**The Simulator cannot build this project.** MobileVLCKit 3.7.3 ships its
simulator slice in a directory named `ios-arm64_i386_x86_64-simulator`; the
binary does contain `arm64`, but Xcode's xcframework resolver keys off the
directory name and rejects it on Apple Silicon. Build for `iphoneos` instead —
which is also the only place the camera protocol can actually be exercised.

## Layout

| File | Role |
| --- | --- |
| `Sources/AmbarellaProtocol.swift` | msg_id / rval / notification lookup tables |
| `Sources/YiCameraClient.swift` | TCP socket, session token, request routing |
| `Sources/YiFileManager.swift` | Listing, deleting, downloading media |
| `Sources/RTSPPlayerView.swift` | MobileVLCKit viewfinder wrapper |
| `Sources/*View.swift` | SwiftUI screens |

`YiCameraClient` is `@MainActor` and owns all connection state; views observe it
and never touch the socket directly.

## Thumbnail sidecars

The camera writes a preview beside every capture, in **two different forms**:

| Media | Sidecar | Preview |
| --- | --- | --- |
| `YDXJ0183.jpg` | `YDXJ0183.THM` | JPEG, decoded directly |
| `YDXJ0182.mp4` | `YDXJ0182_thm.mp4` | short clip; extract frame 0 |

The `1282` listing returns both as ordinary entries, so:

- **Filter them out of the gallery** (`YiFile.isThumbnail`, which matches the
  `.THM` extension *and* a `_thm` filename suffix) or the list doubles in length
  — a `_thm.mp4` otherwise shows up as a second tiny video beside every real one.
  Match the suffix on the extension-stripped stem, not as a substring, so a file
  genuinely named `thumb.mp4` is not swallowed.
- **Use them as previews.** This is the only practical way to preview a video —
  the alternative is downloading hundreds of megabytes to decode one frame.
  Video sidecars need `AVAssetImageGenerator`, which requires a local file, so
  the (small) clip is downloaded to `temporaryDirectory` and deleted after.
  Photos fall back to the original when no `.THM` exists.
- **Delete the sidecar with its media**, or the card accumulates orphans for
  content that no longer exists. **Only delete a sidecar the listing actually
  reported** — the path can be derived from the media name, but deriving it does
  not mean the file exists, and deleting a non-existent path draws `-1` or `-13`
  from the camera. `YiFileManager.sidecarPaths` records what was listed.

## The camera has more than one FUSE mount

`/tmp/fuse_d/` is the SD card, and the HTTP server serves it from the root —
`/tmp/fuse_d/DCIM/100MEDIA/x.jpg` is fetched as `http://192.168.42.1/DCIM/100MEDIA/x.jpg`.

But it is not the only mount. `GET_DEVICE_INFO` reports the camera's logo as
`/tmp/fuse_z/app_logo.jpg` — internal flash, not the card. How the HTTP server
exposes that is undocumented, so `logoURLCandidates` strips any `/tmp/fuse_X/`
prefix and falls back to the bare filename and the verbatim path, logging which
one worked. **Do not assume `mediaRoot` is the only prefix to strip.**

## App Transport Security

**The camera's HTTP file server needs an ATS exception.** Media, thumbnails and
the capture preview are all fetched from `http://192.168.42.1/…` in cleartext —
the camera has no TLS and its network has no CA. iOS blocks cleartext by
default, so without the `NSExceptionDomains` entry for `192.168.42.1` in
`Info.plist` **every HTTP request fails**, while the app still looks healthy:
the control channel is a raw `NWConnection` TCP socket and is unaffected, so
listing, capture and settings all work while the gallery silently shows no
images and downloads never arrive.

Scope it to the camera's address. Do not set `NSAllowsArbitraryLoads`.

## Thumbnail cache

Thumbnails persist to `Caches/Thumbnails/<cameraID>/` via `ThumbnailCache`, so
the gallery repopulates on launch without touching the camera. Every miss costs
an HTTP fetch over the camera's slow link — and for video, a sidecar download
plus a frame decode.

- **Partitioned per camera.** The camera restarts numbering at `YDXJ0001` on
  each fresh card, so a cache keyed by filename alone would serve one camera's
  thumbnail for another's file. `YiCameraClient.cameraID` prefers the serial
  number from `GET_DEVICE_INFO` and falls back to brand+model+firmware; it is
  sanitised because it is used as a path component.
- **Keyed by name + size + timestamp**, so a recycled filename with different
  content misses rather than showing the previous file's image.
- **Evicted after a full listing.** Once `listFiles()` completes, the listing is
  authoritative: anything cached for that camera and not in it refers to deleted
  media. Deleting a file also drops its entry immediately. A 128 MB ceiling
  trims oldest-first.

## Downloads

Media downloaded from the camera goes to the **camera roll** via
`PhotoLibrarySaver`. It is staged in `temporaryDirectory` and deleted once
Photos has copied it.

Do **not** save to the app's `documentDirectory`: without `UIFileSharingEnabled`
that container is invisible to the user and never reclaimed, so downloads
silently accumulate somewhere they can never be opened. (That was the original
behaviour.) Authorisation is requested as `.addOnly`, which does not grant read
access to the user's existing library, and `NSPhotoLibraryAddUsageDescription`
must stay in `Info.plist` or the request traps at runtime.

Photos infers photo-vs-video from the file extension, so the staged filename
must keep the camera's original name.

## SD card behaviour

Observed on real hardware, not documented upstream:

- **`FORMAT` (4) returns `rval: 0` when the request is *accepted*, not when the
  card is ready.** The card reports `-27` (busy) for several seconds afterwards,
  during which every other command fails. `formatSDCard()` therefore polls until
  the card responds, then confirms `DCIM/100MEDIA` exists — a format that
  "succeeds" but leaves the directory missing means the card is not writable.
- **`-28` means capture is impossible because there is no usable card.**
  `TAKE_PHOTO` and `RECORD_START` return it while the card is unwritable, even
  though `GET_BATTERY_LEVEL` and `GET_DEVICE_INFO` still return 0. Do not read a
  healthy battery response as a healthy card.
- **`FORMAT` acts on the mounted volume `D:`, which is the `/tmp/fuse_d` FUSE
  mount.** So a card the camera cannot *mount* cannot be *formatted* either —
  `FORMAT` returns 0, runs, and changes nothing. `-26` on the very first listing
  of a session (before any format) is the tell: the card was never mounted.
- Use `GET_SPACE` (5, `type: "free"|"total"`) to tell the two `-26` cases apart.
  A mounted-but-empty card reports real capacity; an unmountable one reports 0.
  `formatSDCard()` checks this first and refuses to issue a pointless format.
- The requirement is stricter than "FAT32": a **single primary MBR partition**,
  FAT32, 32 KB allocation unit, ≤64 GB. GPT, a missing partition table, or
  exFAT (the default on 64 GB cards) all fail to mount. See the README
  troubleshooting section for the `diskutil` repair sequence.
- Long operations set `isBusy`, which pauses the heartbeat. Without that, the
  5-second poll logs spurious `-27` failures throughout a format.

## Gotchas

- **The API scanner is destructive.** `scanUndocumentedCommands` sweeps unknown
  `msg_id`s, and unknown commands can hang or reboot the camera's TCP server.
  Keep it behind the debug toggle and keep the inter-command delay.
- **The filesystem explorer walks breadth-first, by depth — never recursively.**
  `1282` lists any path, not just `DCIM`, so the camera's whole Linux root is
  reachable. `FilesystemExplorer` lists every directory at depth N before any at
  N+1, which bounds the blast radius of each extra level.
  **Nothing is excluded by path** — `/proc`, `/sys` and `/dev` are walked too,
  by design. Only three things stop it running away: the depth limit, the
  entry/per-level caps, and the `visited` set. That set plus the `.`/`..` filter
  are not policy — without them a symlink cycle such as `/proc/self/cwd` never
  terminates. The inter-request delay is likewise load-bearing; don't remove it.
  Directories are inferred by *failing* to parse a `"<size> bytes|<date>"`
  value, since firmwares report them inconsistently.
- `DirectoryBrowserView` is the interactive counterpart: one `1282` per tap,
  drilling down via `NavigationLink`. Prefer it over raising the walk depth.
- **Never gate navigation on `isDirectory`.** A listing cannot reliably identify
  a directory: on Linux they usually report a real block size (`4096 bytes`),
  which is indistinguishable from a file. Gating `NavigationLink` on it made
  every real directory un-tappable. Every row is a link; opening a plain file
  just lists nothing. `isDirectory` drives the icon only, and remains a
  heuristic (a genuine 4096-byte file shows a folder icon — harmless).
- **Do not put `.textSelection(.enabled)` on a row inside a `NavigationLink`.**
  It intercepts the tap gesture and the link silently never fires.
- **`msg_id` 4 formats the SD card** and 12 powers the camera off. Both are
  irreversible from the app's side — they need a confirmation step.
- Camera clock has no battery-backed RTC, so it resets whenever the battery is
  pulled. `syncClock()` sets it from the phone on every connect (gated by the
  `syncClockOnConnect` preference) via
  `{"msg_id":2,"type":"camera_clock","param":"yyyy-MM-dd HH:mm:ss"}`. The
  formatter must use the `en_US_POSIX` locale — a device set to a non-Gregorian
  calendar would otherwise send a year the camera cannot parse.
- **Photos access is add-only, and must stay that way.** `PHAsset.fetchAssets`
  and `PHAssetCollection.fetchAssetCollections` are *read* APIs: they require
  `NSPhotoLibraryUsageDescription` and full library access, and **crash the app
  outright** without it. That is why there is no "Yippy!" album — filing assets
  into one needs those fetches to resolve placeholders. Saving to the camera
  roll needs only `NSPhotoLibraryAddUsageDescription`; do not add a read API to
  gain an album.
- **Do not delete the staged download in a `defer`.** Photos copies from that
  URL during the save; removing it before the save completes loses the asset.
