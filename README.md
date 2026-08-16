# Xiaomi Yi Action Camera iOS Controller

## Overview

The Xiaomi Yi Action Camera iOS Controller is a modern, open-source mobile application designed to interface with the legacy Xiaomi Yi Action Camera. Developed as a replacement for the deprecated official client, this application restores complete user control over the camera's hardware by leveraging its proprietary TCP/JSON communication protocol and HTTP media server. 

Built entirely in Swift and SwiftUI, the application utilizes modern iOS architectural patterns, including Swift Concurrency (async/await) and Combine, ensuring robust state management and resilient network handling.

## Core Capabilities

*   **Hardware Interfacing:** Direct socket communication via the Ambarella A7LS chipset protocol (TCP Port 7878).
*   **Low-Latency Viewfinder:** Integrated RTSP streaming wrapper utilizing MobileVLCKit for real-time video monitoring.
*   **Media Management:** Built-in gallery supporting parsing, localized downloading, and remote deletion of media files directly from the camera's HTTP file server.
*   **State Synchronization:** Continuous heartbeat monitoring and asynchronous event handling for real-time battery and hardware status updates.
*   **API Discovery Module:** A built-in diagnostic scanner engineered to map and log undocumented firmware endpoints for advanced development and research.

## Build Instructions

### Prerequisites

*   macOS 13.0 or later
*   Xcode 14.0 or later
*   XcodeGen (available via Homebrew: `brew install xcodegen`)
*   CocoaPods (available via RubyGems: `sudo gem install cocoapods`)
*   A physical iOS device (iOS 16.0+) for network compatibility

### Installation Steps

1.  **Generate the Xcode Project:**
    Navigate to the project root directory and execute XcodeGen to build the `.xcodeproj` from the YAML specification.
    ```bash
    xcodegen generate
    ```

2.  **Resolve Dependencies:**
    Install the required third-party frameworks (MobileVLCKit) via CocoaPods.
    ```bash
    pod install
    ```

3.  **Open the Workspace:**
    Do not open the standard project file. Open the generated workspace file to ensure CocoaPod dependencies are properly linked.
    ```bash
    open YiCamera.xcworkspace
    ```

4.  **Configure Code Signing:**
    Within Xcode, select the `YiCamera` target. Navigate to the "Signing & Capabilities" tab, enable "Automatically manage signing," and select your Apple Developer Team.

5.  **Deploy to Device:**
    Connect a physical iOS device to your development machine. Select the device as the active run destination and initiate the build sequence (`Cmd + R`).

## Usage

To utilize the application, the iOS device must be connected directly to the camera's local area network.
1. Power on the Xiaomi Yi Action Camera and activate its Wi-Fi module.
2. Open the iOS Settings application and connect to the network broadcasting the `YDXJ_` SSID prefix (Default password: `1234567890`).
3. Launch the YiCamera application and follow the connection wizard.
