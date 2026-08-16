<div align="center">

<img src="YippyLogo.png" alt="Yippy!" width="140">

# Yippy!

**An iOS controller for the Xiaomi Yi Action Camera.**

[![Platform](https://img.shields.io/badge/platform-iOS%2016%2B-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

</div>

---

The official Xiaomi Yi app is gone from the App Store. Yippy! replaces it —
talking to the camera over its Ambarella JSON-over-TCP control protocol, RTSP
for live view, and plain HTTP for media, all reverse-engineered by the community
(see [Acknowledgements](#acknowledgements)).

Written in Swift and SwiftUI, using structured concurrency throughout.

## Features

|  | |
| --- | --- |
| **Live viewfinder** | RTSP stream via MobileVLCKit, forced over TCP for the camera's gateway-less network |
| **Capture** | Photo and video, with recording state driven by the camera's own notifications rather than optimistic UI |
| **Gallery** | Thumbnails from the camera's `.THM` sidecars, full-screen viewer with pinch-zoom, and save straight to your photo library |
| **Camera settings** | Resolution, quality, metering and more — discovered from the camera at runtime, so it reflects your firmware rather than a hardcoded list |
| **Clock sync** | Sets the camera's clock on connect; it has no backup battery, so timestamps are otherwise wrong |
| **Storage** | Card capacity, format, and diagnostics that distinguish "empty card" from "unmountable card" |
| **Debug tools** | Filesystem browser and an API scanner for probing undocumented `msg_id`s |

> [!WARNING]
> **Read [SD Card Requirements](#sd-card-requirements) before use.** Most
> "the camera is broken" reports are a card the camera cannot mount — and its
> own format command reports success while changing nothing.

## Build Instructions

### Requirements

- macOS 13 or later, with Xcode 14+
- [CocoaPods](https://cocoapods.org) — `sudo gem install cocoapods`
- **A physical iOS 16+ device.** The Simulator cannot build this project
  (MobileVLCKit ships no usable arm64 simulator slice), and could not join the
  camera's Wi-Fi even if it could.

### Setup

**1. Install dependencies**

```bash
pod install
```

**2. Open the workspace** — not the `.xcodeproj`, or MobileVLCKit will not link

```bash
open YiCamera.xcworkspace
```

**3. Sign** — select the `YiCamera` target → *Signing & Capabilities* → enable
*Automatically manage signing* and pick your team.

**4. Run** on a connected device (`Cmd + R`).

> [!IMPORTANT]
> This project does **not** use XcodeGen. The `.xcodeproj` is the source of
> truth and is committed — add files and change settings in Xcode directly.
> Running `xcodegen generate` strips the CocoaPods integration and resets the
> bundle identifier.

## SD Card Requirements

**Read this before anything else.** Most "the camera is broken" reports are a
card the camera cannot mount, and the symptoms are misleading: the camera's own
format command reports *success* while changing nothing.

| Requirement | Detail |
| --- | --- |
| Partition scheme | **MBR**, a single primary partition. GPT, no partition table at all, or leftover partitions from another device will not mount. |
| Filesystem | **FAT32**. Not exFAT — cards of 64 GB ship as exFAT and must be reformatted. |
| Allocation unit | **32 KB** |
| Capacity | **64 GB or smaller** (the official ceiling) |
| Speed | Class 10 / UHS-1 or better |
| Authenticity | A genuine card. Counterfeits misreport capacity and fail in exactly this way; SanDisk and Kingston are the most commonly faked. |

"I formatted it as FAT32" does **not** rule the card out — the partition
*scheme* matters as much as the filesystem, and macOS and Windows both produce
GPT or partitionless layouts by default.

### Formatting a card on macOS — Disk Utility

Disk Utility works, but **only if you erase the physical disk rather than the
volume on it.** By default Disk Utility hides the physical disk and shows just
the volume, and erasing a volume cannot change the partition scheme — you keep
whatever the card already had, which is usually the GPT layout the camera
rejects. This is the single most common reason a card "formatted as FAT32" still
does not work.

1. Insert the card and open **Disk Utility** (Applications → Utilities).
2. Choose **View → Show All Devices**. This is required — without it the disk you
   need is not listed.
3. In the sidebar, select the **top-level disk entry**, not the indented volume
   beneath it. The top-level entry shows the manufacturer and total size (e.g.
   *"Generic MassStorage Media"*, 32 GB); the indented one is the volume (e.g.
   *"Untitled"*). Selecting the wrong one is the mistake this step exists to
   prevent.
4. Click **Erase**.
5. Set the fields:
   - **Name:** anything (e.g. `YI`)
   - **Format:** **MS-DOS (FAT32)** — this is what FAT32 is called in the GUI
   - **Scheme:** **Master Boot Record** — the critical setting, and it only
     appears when a physical disk is selected in step 3
6. Click **Erase**, then **Done**.
7. Confirm the result: with the disk selected, Disk Utility should report
   *Partition Map Scheme: Master Boot Record*. If the Scheme field was never
   offered, you erased a volume — go back to step 2.

> **If MS-DOS (FAT32) is missing from the Format list** — which can happen on
> larger cards, where macOS steers you toward ExFAT — use the command-line
> method below. `diskutil eraseDisk FAT32` will format cards the GUI declines to.

### Formatting a card on macOS — Terminal

More reliable than the GUI, and the only option when Disk Utility will not offer
FAT32. Identify the card first — get this wrong and you will erase the wrong
disk:

```bash
diskutil list
```

Find the entry matching your card's size (e.g. `/dev/disk4`) and confirm it is
marked *external, physical*. Then erase it with an MBR scheme — `MBRFormat` is
the part that matters, and is what most guides omit:

```bash
sudo diskutil eraseDisk FAT32 YI MBRFormat /dev/disk4
```

Verify the result: the card must show **one `DOS_FAT_32` partition** under an
**`FDisk_partition_scheme`**.

```bash
diskutil list /dev/disk4
```

### Finally, format on the camera

Whichever method you used, put the card in the camera and **format it once on
the camera as well** (Settings → Storage → Format SD Card), so the camera
creates its own `DCIM/100MEDIA` directory.

### If the card still is not recognised

Symptoms: the gallery stays empty, listing returns `-26`, capture returns `-28`,
and Settings reports `0 GB` total.

The camera cannot mount the card, and **`FORMAT` operates on the mounted volume
`D:`** (the `/tmp/fuse_d` FUSE mount) — no mount means the format has nothing to
act on, which is why it claims success and accomplishes nothing. Yippy! checks
free space before formatting and refuses to issue a format it knows is futile.

Wipe the partition table outright and rebuild it:

```bash
sudo diskutil unmountDisk /dev/disk4
sudo dd if=/dev/zero of=/dev/rdisk4 bs=1m count=10   # destroys the partition table
```

Then either repeat the `eraseDisk` above, or format the card in an **Android
phone** — that is the fix most frequently reported as working when nothing else
has. If a known-good card from a different brand also fails, the card slot
itself is suspect.

## Usage

The camera is its own Wi-Fi access point, so the phone joins the camera's
network — there is no internet on it while connected.

1. Power the camera on and enable its Wi-Fi.
2. In iOS **Settings → Wi-Fi**, join the `YDXJ_…` network.
   The default password is `1234567890`.
3. Open **Yippy!** and tap Connect.

| | |
| --- | --- |
| Camera IP | `192.168.42.1` |
| Control channel | TCP `7878`, newline-delimited JSON |
| Live view | `rtsp://192.168.42.1/live` |
| Media | `http://192.168.42.1/…` |

## Acknowledgements

There is no vendor-published specification for this camera's control protocol.
Everything Yippy! knows about it comes from people who patiently captured
traffic, disassembled firmware, and published what they found — for free, with
nothing to gain from it. This app would not exist without them, and I'm grateful
for their work.

| Reference | What it made possible |
| --- | --- |
| [Xiaomi Yi JSON Protocol Reverse Engineering](https://gist.github.com/pbaja/f57e6cff7fa14601f6b256926aa33437) — pbaja | The most complete public `msg_id` map, plus the `rval` error codes and the exact `{"msg_id":259,"type":"app_status","param":"none_force"}` request that starts the RTSP viewfinder |
| [SJCAM SJ8 Pro Ambarella WiFi API](https://www.rigacci.org/wiki/doku.php/doc/appunti/hardware/sjcam-8pro-ambarella-wifi-api) — Niccolò Rigacci | Canonical `AMBA_*` constant names, the session/token handshake, and confirmation that `AMBA_BOSS_RESETVF` is required before live video is available |
| [Xiaomi Yi protocol notes](https://gist.github.com/franga2000/1be2aa18cb3409e57af149883c06e34a) — franga2000 | Asynchronous `msg_id: 7` notification types and the settings key vocabulary |
| [yi-action-camera](https://github.com/mariomka/yi-action-camera) — mariomka | A working Node client that served as a reference for command sequencing |
| [Xiaomi_Yi_autoexec](https://github.com/PJanisio/Xiaomi_Yi_autoexec) — PJanisio | Firmware-level context on the camera's internals and storage layout |
| [eyecamcontrol](https://github.com/jmrf/eyecamcontrol) — jmrf | An independent Java implementation useful for cross-checking the protocol |

Thanks also to the [DashCamTalk](https://dashcamtalk.com/) community, whose
forum threads preserved packet captures and firmware findings that appear
nowhere else.

The protocol details gathered from these sources are collected in
[`Sources/AmbarellaProtocol.swift`](Sources/AmbarellaProtocol.swift). Codes that
only one source attests, and which this project has not confirmed against real
hardware, are marked `// unverified` there rather than presented as fact.

## Disclaimer & Legal

**Disclaimer of Liability:** This software is provided "as is", without warranty of any kind, express or implied. The developer makes no guarantees regarding the functionality, reliability, or safety of this application. By using this software, you assume all risks associated with its use, including but not limited to the risk of data loss, SD card corruption, or permanent damage to the camera hardware. Use at your own risk.

**Trademark Notice:** Xiaomi, Yi, and Ambarella are trademarks or registered trademarks of their respective owners. This project is an independent, community-driven, open-source initiative and is not affiliated with, endorsed by, or sponsored by Xiaomi Inc., Xiaoyi Technology, or Ambarella.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
