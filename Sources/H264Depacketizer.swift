import Foundation

/// Reassembles H.264 access units from RTP packets, per RFC 6184.
///
/// The camera advertises `packetization-mode=1`, which means three payload
/// shapes can arrive:
///
///  - **Single NAL** (type 1–23): the payload *is* the NAL unit.
///  - **STAP-A** (type 24): several NAL units in one packet, each prefixed
///    with a 16-bit big-endian length.
///  - **FU-A** (type 28): one NAL unit split across packets, with start and
///    end markers in the FU header.
///
/// Output is in AVCC form (4-byte big-endian length prefix per NAL), which is
/// what `CMBlockBuffer` and `VTDecompressionSession` expect — not the Annex B
/// start codes used in files.
struct H264Depacketizer {

    /// A complete NAL unit, length-prefixed, ready for the decoder.
    private(set) var parameterSets: (sps: Data, pps: Data)?

    /// Fragments of an in-progress FU-A, without their length prefix.
    private var fragmentBuffer = Data()
    private var fragmentHeader: UInt8?

    private static let rtpHeaderSize = 12

    /// Feeds one RTP packet, returning any NAL units it completed.
    ///
    /// Returns an empty array for a mid-fragment packet — that is normal, not
    /// an error.
    mutating func handle(rtpPacket packet: Data) -> [Data] {
        // RTP header: 2 bytes flags, 2 sequence, 4 timestamp, 4 SSRC, then
        // 4 bytes per CSRC. The CSRC count is the low nibble of byte 0.
        guard packet.count > Self.rtpHeaderSize else { return [] }
        let csrcCount = Int(packet[packet.startIndex] & 0x0F)
        var offset = Self.rtpHeaderSize + csrcCount * 4

        // An extension header, if present, is 4 bytes of its own plus a
        // length given in 32-bit words.
        if packet[packet.startIndex] & 0x10 != 0 {
            guard packet.count >= offset + 4 else { return [] }
            let lengthIndex = packet.index(packet.startIndex, offsetBy: offset + 2)
            let words = Int(packet[lengthIndex]) << 8
                | Int(packet[packet.index(after: lengthIndex)])
            offset += 4 + words * 4
        }

        guard packet.count > offset else { return [] }
        let payload = packet.subdata(in: packet.index(packet.startIndex, offsetBy: offset)..<packet.endIndex)
        return handle(payload: payload)
    }

    private mutating func handle(payload: Data) -> [Data] {
        guard let first = payload.first else { return [] }
        let type = first & 0x1F

        switch type {
        case 1...23:
            return [payload]
        case 24:
            return unpackSTAPA(payload)
        case 28:
            return unpackFUA(payload)
        default:
            // STAP-B, MTAP and FU-B are legal but unused at
            // packetization-mode=1, so ignoring them costs nothing here.
            return []
        }
    }

    /// STAP-A: `[NAL header][len16][NAL][len16][NAL]…`
    private func unpackSTAPA(_ payload: Data) -> [Data] {
        var units: [Data] = []
        var index = payload.index(after: payload.startIndex) // skip STAP-A header

        while payload.distance(from: index, to: payload.endIndex) >= 2 {
            let length = Int(payload[index]) << 8
                | Int(payload[payload.index(after: index)])
            index = payload.index(index, offsetBy: 2)
            guard length > 0,
                  payload.distance(from: index, to: payload.endIndex) >= length else { break }
            units.append(payload.subdata(in: index..<payload.index(index, offsetBy: length)))
            index = payload.index(index, offsetBy: length)
        }
        return units
    }

    /// FU-A: `[FU indicator][FU header][fragment]`.
    ///
    /// The original NAL header is rebuilt from the indicator's F and NRI bits
    /// plus the type carried in the FU header — the original header byte is
    /// never transmitted.
    private mutating func unpackFUA(_ payload: Data) -> [Data] {
        guard payload.count > 2 else { return [] }
        let indicator = payload[payload.startIndex]
        let fuHeader = payload[payload.index(after: payload.startIndex)]

        let isStart = fuHeader & 0x80 != 0
        let isEnd = fuHeader & 0x40 != 0
        let nalType = fuHeader & 0x1F
        let fragment = payload.subdata(in: payload.index(payload.startIndex, offsetBy: 2)..<payload.endIndex)

        if isStart {
            // F and NRI from the indicator, type from the FU header.
            fragmentHeader = (indicator & 0xE0) | nalType
            fragmentBuffer = Data([fragmentHeader!])
        }

        // A fragment arriving without its start (a lost packet) cannot be
        // reassembled; drop the whole NAL rather than emitting a corrupt one.
        guard fragmentHeader != nil else { return [] }
        fragmentBuffer.append(fragment)

        guard isEnd else { return [] }
        let completed = fragmentBuffer
        fragmentBuffer = Data()
        fragmentHeader = nil
        return [completed]
    }

    /// Records SPS/PPS as they arrive in-band, so the decoder can be
    /// configured even if the SDP did not carry them.
    ///
    /// Returns `true` only when the sets actually changed, so callers can skip
    /// reconfiguring the decoder. Parameter sets repeat before every IDR, so a
    /// caller that reconfigures on each sighting rebuilds the format
    /// description several times a second for identical bytes.
    @discardableResult
    mutating func noteParameterSets(from units: [Data]) -> Bool {
        var sps: Data?
        var pps: Data?
        for unit in units {
            guard let first = unit.first else { continue }
            switch first & 0x1F {
            case 7: sps = unit
            case 8: pps = unit
            default: break
            }
        }
        // Nothing here carried parameter sets — the common case, so leave
        // before touching any stored state.
        guard sps != nil || pps != nil else { return false }

        guard let newSPS = sps ?? parameterSets?.sps,
              let newPPS = pps ?? parameterSets?.pps else { return false }
        guard newSPS != parameterSets?.sps || newPPS != parameterSets?.pps else { return false }
        parameterSets = (newSPS, newPPS)
        return true
    }

    /// Parses `sprop-parameter-sets` from the SDP's `a=fmtp` line — a
    /// comma-separated pair of base64 NAL units, SPS first.
    static func parameterSets(fromSDP sdp: String) -> (sps: Data, pps: Data)? {
        let lines = sdp.unicodeScalars
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String(String.UnicodeScalarView($0)) }

        for line in lines where line.contains("sprop-parameter-sets=") {
            guard let range = line.range(of: "sprop-parameter-sets=") else { continue }
            // The attribute may be followed by further ";"-separated fields.
            let value = line[range.upperBound...].prefix { $0 != ";" && $0 != " " }
            let parts = value.split(separator: ",")
            guard parts.count >= 2,
                  let sps = Data(base64Encoded: String(parts[0])),
                  let pps = Data(base64Encoded: String(parts[1])),
                  !sps.isEmpty, !pps.isEmpty else { continue }
            return (sps, pps)
        }
        return nil
    }

    /// Wraps NAL units in the 4-byte big-endian length prefixes that
    /// `CMBlockBuffer` expects (AVCC), rather than Annex B start codes.
    static func avcc(_ units: [Data]) -> Data {
        var out = Data()
        // Sized up front: a multi-NAL keyframe would otherwise reallocate and
        // copy a large buffer several times as it grows.
        out.reserveCapacity(units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }
}
