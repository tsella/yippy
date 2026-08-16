import Foundation
import CoreMedia

/// Depacketises RTP off the main thread.
///
/// `RTSPStream` is `@MainActor` because it publishes state and drives an
/// `AVSampleBufferDisplayLayer`, which must be touched on the main thread. But
/// depacketisation is pure computation over bytes, and running it on the main
/// actor put a `subdata` copy, an AVCC rebuild and an allocation on the UI
/// thread for **every datagram** — thousands per session, at frame rate.
///
/// This actor owns the depacketiser and the RTP parsing, so only completed
/// access units cross back to the main actor: one hop per *frame* rather than
/// one per *packet*, and the fragment reassembly never touches the UI thread.
actor RTPDecoder {

    /// A complete access unit, ready for the display layer.
    struct Frame: Sendable {
        let avcc: Data
        let presentationTime: CMTime
        /// Set when this frame's parameter sets differ from the previous ones,
        /// so the caller reconfigures the decoder only when it must.
        let parameterSets: (sps: Data, pps: Data)?
    }

    private var depacketizer = H264Depacketizer()

    /// Frames carry a 90 kHz RTP timestamp; `CMTime` wants a timescale.
    private static let clockRate: Int32 = 90_000

    func reset() {
        depacketizer = H264Depacketizer()
    }

    /// Seeds the depacketiser with parameter sets parsed from the SDP, so the
    /// first in-band repeat is recognised as unchanged rather than a change.
    func seed(sps: Data, pps: Data) {
        depacketizer.noteParameterSets(from: [sps, pps])
    }

    /// Feeds one datagram, returning a frame if it completed an access unit.
    func decode(_ packet: Data) -> Frame? {
        guard !packet.isEmpty else { return nil }

        let units = depacketizer.handle(rtpPacket: packet)
        guard !units.isEmpty else { return nil }

        // Parameter sets arrive in-band and they change: the camera reconfigures
        // its encoder when recording starts, so the SDP's sets go stale
        // mid-session. They repeat before every IDR, so only report a change.
        var changedSets: (sps: Data, pps: Data)?
        if depacketizer.noteParameterSets(from: units) {
            changedSets = depacketizer.parameterSets
        }

        let time = CMTime(value: CMTimeValue(Self.timestamp(of: packet)),
                          timescale: Self.clockRate)
        return Frame(avcc: H264Depacketizer.avcc(units),
                     presentationTime: time,
                     parameterSets: changedSets)
    }

    /// The RTP timestamp: bytes 4–7, big-endian.
    private static func timestamp(of packet: Data) -> UInt32 {
        guard packet.count >= 8 else { return 0 }
        let base = packet.index(packet.startIndex, offsetBy: 4)
        return packet[base...].prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
