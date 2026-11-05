import CoreMedia
import Foundation

struct H264DecodedPacket {
    let sample: CMSampleBuffer?
    let formatChanged: Bool
    let isKeyframe: Bool
}

/// Converts scrcpy's Annex B access units to AVCC and tracks decoder configuration changes.
struct H264SampleBuilder {
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private let display: DisplayInfo

    init(display: DisplayInfo) { self.display = display }

    mutating func requireKeyframe() { waitingForKeyframe = true }

    mutating func packet(_ payload: Data, header: ScrcpyPacketHeader) throws -> H264DecodedPacket {
        let units = try H264AnnexB.nalUnits(payload)
        var changed = false
        var picture = false
        var isKeyframe = header.isKeyframe
        var frameUnits: [Data] = []
        for unit in units {
            let kind = unit[unit.startIndex] & 0x1F
            switch kind {
            case 7:
                if sps != unit { sps = unit; changed = true }
            case 8:
                if pps != unit { pps = unit; changed = true }
            default:
                if (1...5).contains(kind) { picture = true }
                if kind == 5 { isKeyframe = true }
                frameUnits.append(unit)
            }
        }
        var formatChanged = false
        if changed, let sps, let pps {
            let next = try Self.formatDescription(sps: sps, pps: pps)
            let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(next,
                usePixelAspectRatio: true, useCleanAperture: true)
            try AndroidVideoGeometry.validate(width: Int(dimensions.width.rounded()),
                                              height: Int(dimensions.height.rounded()), display: display)
            format = next
            waitingForKeyframe = true
            formatChanged = true
        }
        guard picture else {
            return H264DecodedPacket(sample: nil, formatChanged: formatChanged, isKeyframe: false)
        }
        guard !header.isConfiguration else { throw ScrcpyVideoError.malformed("configuration packet contains a video frame") }
        guard let format else { throw ScrcpyVideoError.malformed("video frame arrived before SPS/PPS") }
        guard !waitingForKeyframe || isKeyframe else {
            return H264DecodedPacket(sample: nil, formatChanged: formatChanged, isKeyframe: false)
        }
        waitingForKeyframe = false
        let avcc = H264AnnexB.avcc(frameUnits)
        let pts = CMTime(value: Int64(header.presentationTime), timescale: 1_000_000)
        guard let sample = VideoSampleBuffer.make(avcc, format: format, isKey: isKeyframe, presentationTime: pts) else {
            throw ScrcpyVideoError.decoder("could not create an H.264 sample buffer")
        }
        return H264DecodedPacket(sample: sample, formatChanged: formatChanged, isKeyframe: isKeyframe)
    }

    private static func formatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { sequence in
            pps.withUnsafeBytes { picture in
                let pointers = [sequence, picture].map { $0.bindMemory(to: UInt8.self).baseAddress! }
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { throw ScrcpyVideoError.decoder("invalid SPS/PPS (\(status))") }
        return description
    }
}
