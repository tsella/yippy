import SwiftUI
import AVFoundation
import VideoToolbox

/// Displays H.264 access units using `AVSampleBufferDisplayLayer`.
///
/// The layer decodes and renders in one step, so no `VTDecompressionSession` is
/// needed — we hand it `CMSampleBuffer`s built from the depacketised NALs and
/// a format description derived from the SPS/PPS.
final class H264StreamLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private var formatDescription: CMVideoFormatDescription?
    private var enqueued = 0
    private var failureCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Builds the format description from the parameter sets. Must be called
    /// before any frame is enqueued, and again if they change mid-stream.
    func configure(sps: Data, pps: Data) {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    // 4, matching the AVCC prefixes the depacketiser emits.
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            print("[h264] format description failed: \(status)")
            return
        }

        // Compare the *descriptions*, not the raw parameter-set bytes. This
        // camera's in-band SPS is not byte-identical to the SDP's even when it
        // describes the same format, so a byte comparison upstream reports a
        // spurious change on the first IDR of every session.
        if let existing = formatDescription, CMFormatDescriptionEqual(existing, otherFormatDescription: description) {
            return
        }
        formatDescription = description

        // The SPS carries the real frame size. Report it so the view can size
        // itself to the video rather than assuming an aspect ratio — this
        // camera changes encoder configuration between modes.
        let size = CMVideoFormatDescriptionGetDimensions(description)
        if size.width > 0, size.height > 0 {
            let ratio = CGFloat(size.width) / CGFloat(size.height)
            print("[h264] video is \(size.width)×\(size.height)")
            onAspectRatio?(ratio)
        }
    }

    /// Called when the stream's aspect ratio becomes known or changes.
    var onAspectRatio: ((CGFloat) -> Void)?

    /// Enqueues one access unit, already in AVCC form.
    func enqueue(_ avcc: Data, presentationTime: CMTime) {
        guard let formatDescription else { return }

        // CoreMedia needs the bytes to outlive this call, so allocate a block
        // it owns and copy into it rather than pointing at a local Data.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return }

        let copied = avcc.withUnsafeBytes { bytes -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        let data = avcc

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var sampleSize = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        // Display immediately — this is a live viewfinder, not playback.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                           to: CFMutableDictionary.self)
            CFDictionarySetValue(attachment,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        // The layer can reject samples silently: the RTP path keeps counting
        // frames while nothing reaches the screen, which looks like a working
        // stream in the log and a black rectangle on the device. Report the
        // reason rather than flushing it away unexamined.
        if displayLayer.status == .failed {
            let reason = displayLayer.error.map { "\($0)" } ?? "unknown"
            print("[h264] display layer failed (\(reason)) — flushing and recovering")
            displayLayer.flush()
            failureCount += 1
        }
        displayLayer.enqueue(sampleBuffer)
        enqueued += 1

        // One line per ~5s at 30fps, enough to tell "frames are reaching the
        // layer" from "frames stopped" without flooding the console.
        if enqueued % 150 == 0 {
            print("[h264] \(enqueued) samples enqueued, status=\(statusName), failures=\(failureCount)")
        }
    }

    private var statusName: String {
        switch displayLayer.status {
        case .unknown:  "unknown"
        case .rendering: "rendering"
        case .failed:   "failed"
        @unknown default: "?"
        }
    }

    func reset() {
        displayLayer.flushAndRemoveImage()
        formatDescription = nil
        enqueued = 0
        failureCount = 0
    }
}

/// SwiftUI wrapper that drives the layer from an `RTSPStream`.
struct H264StreamView: UIViewRepresentable {
    @ObservedObject var stream: RTSPStream

    func makeUIView(context: Context) -> H264StreamLayerView {
        let view = H264StreamLayerView()
        view.onAspectRatio = { [weak stream] ratio in
            Task { @MainActor in stream?.noteAspectRatio(ratio) }
        }
        stream.attach(view)
        return view
    }

    func updateUIView(_ uiView: H264StreamLayerView, context: Context) {}

    static func dismantleUIView(_ uiView: H264StreamLayerView, coordinator: ()) {
        uiView.reset()
    }
}
