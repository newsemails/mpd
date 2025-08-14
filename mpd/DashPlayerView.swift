//
//  DashPlayerView.swift
//  mpd
//
//  Created by Dufaux, Damiaan on 13/08/2025.
//

import UIKit
import AVFoundation
import VideoToolbox

// MARK: - View that owns AVSampleBufferDisplayLayer

final class DashPlayerView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var timebase: CMTimebase?
    let player: DashSampleBufferPlayer

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    init(frame: CGRect, player: DashSampleBufferPlayer) {
        self.player = player
        super.init(frame: frame)
        guard let layer = self.layer as? AVSampleBufferDisplayLayer else { return }
        displayLayer.frame = bounds
        layer.videoGravity = .resizeAspect
        layer.controlTimebase = makeTimebase()
        player.attach(displayLayer: layer)
        backgroundColor = .black
    }

    convenience init(player: DashSampleBufferPlayer) {
        self.init(frame: .zero, player: player)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeTimebase() -> CMTimebase {
        var tb: CMTimebase?
        CMTimebaseCreateWithMasterClock(allocator: kCFAllocatorDefault,
                                        masterClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &tb)
        CMTimebaseSetRate(tb!, rate: 0) // paused until play()
        return tb!
    }

    func play(url: URL) {
        if let tb = (layer as? AVSampleBufferDisplayLayer)?.controlTimebase {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1.0)
        }
        player.play(mpdURL: url)
    }

    func stop() {
        if let tb = (layer as? AVSampleBufferDisplayLayer)?.controlTimebase {
            CMTimebaseSetRate(tb, rate: 0)
        }
        player.stop()
    }
}

// MARK: - Core player

final class DashSampleBufferPlayer {

    // Public
    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    func play(mpdURL: URL) {
        stop()
        running = true
        Task.detached { [weak self] in
            await self?.startPipeline(mpdURL: mpdURL)
        }
    }

    func stop() {
        running = false
        decoder?.invalidate()
        decoder = nil
        displayLayer?.flushAndRemoveImage()
        session.invalidateAndCancel()
    }

    // Internals
    private let session: URLSession = .init(configuration: {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return c
    }())

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var decoder: VTDecoder?
    private var running = false

    private let decodeQueue = DispatchQueue(label: "dash.decode.queue")
    private let displayQueue = DispatchQueue(label: "dash.display.queue")

    private struct MPDInfo {
        let baseURL: URL
        let initURL: URL
        let mediaTemplate: String // e.g., "video_$Number$.m4s"
        let startNumber: Int
        let timescale: Int // from @timescale or assume 1 if missing
        let segmentDuration: Int // in timescale units (optional; used as fallback)
    }

    private func startPipeline(mpdURL: URL) async {
        do {
            let mpd = try await fetchData(url: mpdURL)
            let info = try parseMPD(mpd: mpd, mpdURL: mpdURL)

            // 1) Fetch init segment
            let initData = try await fetchData(url: info.initURL)

            // 2) Create decoder from avcC in init segment
            let avcC = try BMFF.findAvcC(in: initData)
            let spspps = try AVCConfig.fromAvcC(avcC)
            decoder = try VTDecoder(format: spspps.formatDescription) { [weak self] output in
                self?.enqueue(pixelBuffer: output.pixelBuffer, pts: output.pts)
            }

            // 3) Stream media segments sequentially
            var number = info.startNumber
            var baseDecodeTime: CMTime = .zero

            while running {
                let mediaURL = info.baseURL.appendingPathComponent(
                    info.mediaTemplate.replacingOccurrences(of: "$Number$", with: String(number))
                )
                let seg = try await fetchData(url: mediaURL)

                let frag = try BMFF.parseFragment(seg)
                baseDecodeTime = frag.baseMediaDecodeTime ?? baseDecodeTime

                // Build per-sample PTS/DTS from trun (compositionTimeOffset optional)
                guard let mdat = frag.mdat else { throw DashError.badSegment("Missing mdat") }
                var cursor = mdat.start // offset into data

                // For each sample in the first (and only) trun:
                for sample in frag.samples {
                    // extract bytes
                    let size = sample.size
                    let sampleBytes = seg.subdata(in: cursor ..< cursor + size)
                    cursor += size

                    // feed compressed sample (length-prefixed NALs) to VT
                    // PTS = base + decodeAccum + cto
                    let dts = baseDecodeTime + sample.decodeTime
                    let pts = dts + sample.compositionOffset

                    try decoder?.decode(nalLengthPrefixed: sampleBytes,
                                        dts: dts,
                                        pts: pts)
                }

                number += 1
            }

            decoder?.finish()

        } catch {
            print("DASH error:", error)
        }
    }

    private func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let layer = displayLayer else { return }
        displayQueue.async {
            var vdesc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &vdesc)
            var timing = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: pts,
                                            decodeTimeStamp: .invalid)
            var sbuf: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescription: vdesc!,
                                                     sampleTiming: &timing,
                                                     sampleBufferOut: &sbuf)
            if let sb = sbuf {
                layer.enqueue(sb)
            }
        }
    }

    // MARK: - Networking

    private func fetchData(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DashError.http
        }
        return data
    }
}

// MARK: - Minimal MPD parser (single Representation + SegmentTemplate)

extension DashSampleBufferPlayer {
    enum DashError: Error {
        case mpdParse(String)
        case badSegment(String)
        case http
    }

    private func parseMPD(mpd: Data, mpdURL: URL) throws -> MPDInfo {
        // Extremely tiny XML walker: looks for BaseURL, Representation, SegmentTemplate attrs.
        // Assumes single period/adaptation/representation, H.264, SegmentTemplate with $Number$.
        struct Found {
            var baseURL: URL?
            var initTemplate: String?
            var mediaTemplate: String?
            var startNumber: Int = 1
            var timescale: Int = 1
            var duration: Int = 0
        }

        let xml = String(data: mpd, encoding: .utf8) ?? ""
        func attr(_ name: String, in line: String) -> String? {
            guard let r = line.range(of: "\(name)=\"") else { return nil }
            let rest = line[r.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                return String(rest[..<end])
            }
            return nil
        }

        var f = Found()

        // BaseURL
        if let baseRange = xml.range(of: "<BaseURL>"),
           let endRange = xml.range(of: "</BaseURL>", range: baseRange.upperBound..<xml.endIndex) {
            let base = String(xml[baseRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            f.baseURL = URL(string: base, relativeTo: mpdURL) ?? mpdURL.deletingLastPathComponent().appendingPathComponent(base)
        } else {
            f.baseURL = mpdURL.deletingLastPathComponent()
        }

        // SegmentTemplate (grab first one)
        if let segTmplRange = xml.range(of: "<SegmentTemplate"),
           let close = xml[segTmplRange.lowerBound...].firstIndex(of: ">") {
            let line = String(xml[segTmplRange.lowerBound...close])
            f.initTemplate  = attr("initialization", in: line)
            f.mediaTemplate = attr("media", in: line)
            if let sn = attr("startNumber", in: line), let n = Int(sn) { f.startNumber = n }
            if let ts = attr("timescale", in: line), let n = Int(ts) { f.timescale = n }
            if let du = attr("duration", in: line), let n = Int(du) { f.duration = n }
        }

        guard let base = f.baseURL,
              let initT = f.initTemplate,
              let mediaT = f.mediaTemplate
        else { throw DashError.mpdParse("Missing BaseURL or SegmentTemplate") }

        let initURL = URL(string: initT, relativeTo: base) ?? base.appendingPathComponent(initT)

        return MPDInfo(baseURL: base,
                       initURL: initURL,
                       mediaTemplate: mediaT,
                       startNumber: f.startNumber,
                       timescale: f.timescale,
                       segmentDuration: f.duration)
    }
}

// MARK: - Very small BMFF helpers for init + moof/mdat fragments

enum BMFF {
    struct Box {
        let type: String
        let start: Int
        let size: Int
    }

    static func boxes(in data: Data, range: Range<Int>? = nil) -> [Box] {
        let r = range ?? 0..<data.count
        var i = r.lowerBound
        var out: [Box] = []
        while i + 8 <= r.upperBound {
            let sz = Int(data.uint32BE(at: i))
            let type = data.fourCC(at: i+4)
            if sz == 0 || sz == 1 { break } // ignore 64-bit / to keep simple
            out.append(Box(type: type, start: i+8, size: sz - 8))
            i += sz
        }
        return out
    }

    // Extract avcC blob from init segment (ftyp + moov). We search moov->trak->mdia->minf->stbl->stsd->avc1->avcC
    static func findAvcC(in initData: Data) throws -> Data {
        func find(_ type: String, _ data: Data, in box: Box?) -> Box? {
            let scope = box != nil ? (box!.start ..< box!.start + box!.size) : (0 ..< data.count)
            return boxes(in: data, range: scope).first { $0.type == type }
        }
        guard let moov = find("moov", initData, in: nil),
              let trak = find("trak", initData, in: moov),
              let mdia = find("mdia", initData, in: trak),
              let minf = find("minf", initData, in: mdia),
              let stbl = find("stbl", initData, in: minf),
              let stsd = find("stsd", initData, in: stbl),
              let avc1 = boxes(in: initData, range: stsd.start ..< stsd.start+stsd.size).first(where: { $0.type == "avc1" || $0.type == "avc3" }),
              let avcC = find("avcC", initData, in: avc1) else {
            throw NSError(domain: "BMFF", code: -1, userInfo: [NSLocalizedDescriptionKey: "avcC not found"])
        }
        return initData.subdata(in: avcC.start ..< avcC.start + avcC.size)
    }

    struct Fragment {
        let baseMediaDecodeTime: CMTime?
        let timescale: Int32
        let samples: [Sample]
        let mdat: Box?
        struct Sample {
            let size: Int
            let decodeTime: CMTime // relative to base
            let compositionOffset: CMTime
        }
    }

    static func parseFragment(_ data: Data) throws -> Fragment {
        // Assumes single track, single traf, single trun, flags carry duration & size & cto
        guard let moof = boxes(in: data).first(where: { $0.type == "moof" }) else {
            throw NSError(domain: "BMFF", code: -2, userInfo: [NSLocalizedDescriptionKey: "moof not found"])
        }
        let children = boxes(in: data, range: moof.start ..< moof.start + moof.size)
        guard let traf = children.first(where: { $0.type == "traf" }) else {
            throw NSError(domain: "BMFF", code: -3, userInfo: [NSLocalizedDescriptionKey: "traf not found"])
        }
        let trafChildren = boxes(in: data, range: traf.start ..< traf.start + traf.size)

        let tfdt = trafChildren.first(where: { $0.type == "tfdt" })
        let trun = trafChildren.first(where: { $0.type == "trun" })
        guard let trunBox = trun else {
            throw NSError(domain: "BMFF", code: -4, userInfo: [NSLocalizedDescriptionKey: "trun missing"])
        }

        // Simplified: timescale is not in moof; caller should know. We assume 90000 if unknown.
        let timescale: Int32 = 90000

        var baseTime: CMTime? = nil
        if let tfdtBox = tfdt {
            // version 1 => 64-bit baseMediaDecodeTime
            let v = data[tfdtBox.start]
            if v == 1 {
                let bmdt = data.uint64BE(at: tfdtBox.start + 4)
                baseTime = CMTime(value: CMTimeValue(bmdt), timescale: timescale)
            } else {
                let bmdt = Int64(data.uint32BE(at: tfdtBox.start + 4))
                baseTime = CMTime(value: bmdt, timescale: timescale)
            }
        }

        // trun
        let trunStart = trunBox.start
        let version = data[trunStart]
        let flags = Int(data.uint24BE(at: trunStart + 1))
        let sampleCount = Int(data.uint32BE(at: trunStart + 4))
        var offset = trunStart + 8

        if (flags & 0x000001) != 0 { // data-offset-present
            offset += 4
        }
        // Ignoring first-sample-flags (0x000004) for brevity
        if (flags & 0x000004) != 0 { offset += 4 }

        var samples: [Fragment.Sample] = []
        var decodeAccum = CMTime.zero

        for _ in 0..<sampleCount {
            var duration: Int32 = 0
            var size: Int32 = 0
            var cto: Int32 = 0

            if (flags & 0x000100) != 0 { duration = Int32(bitPattern: data.uint32BE(at: offset)); offset += 4 }
            if (flags & 0x000200) != 0 { size     = Int32(bitPattern: data.uint32BE(at: offset)); offset += 4 }
            if (flags & 0x000800) != 0 { // sample-composition-time-offset
                if version == 0 {
                    cto = Int32(bitPattern: data.uint32BE(at: offset))
                } else {
                    cto = Int32(bitPattern: data.uint32BE(at: offset)) // already signed
                }
                offset += 4
            }
            // sample-flags present? (0x000400) -> skip 4 bytes if needed
            if (flags & 0x000400) != 0 { offset += 4 }

            let d = CMTime(value: CMTimeValue(duration), timescale: timescale)
            let c = CMTime(value: CMTimeValue(cto), timescale: timescale)
            let s = Int(size)
            let sample = Fragment.Sample(size: s,
                                         decodeTime: decodeAccum,
                                         compositionOffset: c)
            samples.append(sample)
            decodeAccum = decodeAccum + d
        }

        let mdat = boxes(in: data).first(where: { $0.type == "mdat" })
        return Fragment(baseMediaDecodeTime: baseTime, timescale: timescale, samples: samples, mdat: mdat)
    }
}

// MARK: - AVC decoder config (SPS/PPS from avcC)

struct AVCConfig {
    let sps: Data
    let pps: Data
    let nalLengthSize: Int
    let formatDescription: CMFormatDescription

    static func fromAvcC(_ avcC: Data) throws -> AVCConfig {
        // avcC format (ISO/IEC 14496-15). We only read lengthSizeMinusOne, one SPS, one PPS.
        guard avcC.count >= 7 else { throw NSError(domain: "avcC", code: -1) }
        let lengthSizeMinusOne = Int(avcC[4] & 0x03)
        let nalLen = lengthSizeMinusOne + 1

        var i = 5
        let numSPS = Int(avcC[i] & 0x1F); i += 1
        guard numSPS >= 1 else { throw NSError(domain: "avcC", code: -2) }
        let spsLen = Int(avcC.uint16BE(at: i)); i += 2
        let sps = avcC.subdata(in: i ..< i + spsLen); i += spsLen

        let numPPS = Int(avcC[i]); i += 1
        guard numPPS >= 1 else { throw NSError(domain: "avcC", code: -3) }
        let ppsLen = Int(avcC.uint16BE(at: i)); i += 2
        let pps = avcC.subdata(in: i ..< i + ppsLen)

        var format: CMFormatDescription?
        let spsPtr = [sps.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! },
                      pps.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! }]
        let spsSz  = [sps.count, pps.count]
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                                         parameterSetCount: 2,
                                                                         parameterSetPointers: spsPtr,
                                                                         parameterSetSizes: spsSz,
                                                                         nalUnitHeaderLength: Int32(nalLen),
                                                                         formatDescriptionOut: &format)
        guard status == noErr, let fd = format else {
            throw NSError(domain: "avcC", code: Int(status))
        }

        return AVCConfig(sps: sps, pps: pps, nalLengthSize: nalLen, formatDescription: fd)
    }
}

// MARK: - Tiny VideoToolbox decoder wrapper

final class VTDecoder {
    private var session: VTDecompressionSession?
    private let format: CMFormatDescription
    private let callback: (Output) -> Void
    private let queue = DispatchQueue(label: "vt.decoder.callback")

    struct Output {
        let pixelBuffer: CVPixelBuffer
        let pts: CMTime
    }

    init(format: CMFormatDescription, callback: @escaping (Output) -> Void) throws {
        self.format = format
        self.callback = callback

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, infoFlags, imageBuffer, pts, duration in
                guard status == noErr, let pb = imageBuffer else { return }
                let mySelf = Unmanaged<VTDecoder>.fromOpaque(refcon!).takeUnretainedValue()
                mySelf.queue.async {
                    mySelf.callback(Output(pixelBuffer: pb, pts: pts))
                }
            },
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        let attrs: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ] as CFDictionary

        var sess: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                  formatDescription: format,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attrs,
                                                  outputCallback: &callbackRecord,
                                                  decompressionSessionOut: &sess)
        guard status == noErr, let s = sess else {
            throw NSError(domain: "VT", code: Int(status))
        }
        self.session = s
    }

    func decode(nalLengthPrefixed: Data, dts: CMTime, pts: CMTime) throws {
        guard let session else { return }
        var bb: CMBlockBuffer?
        var data = nalLengthPrefixed // copy-on-write
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: &data,
                                                        blockLength: data.count,
                                                        blockAllocator: kCFAllocatorNull,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: data.count,
                                                        flags: 0,
                                                        blockBufferOut: &bb)
        guard status == noErr, let block = bb else {
            throw NSError(domain: "VT", code: Int(status))
        }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: dts)
        var sbuf: CMSampleBuffer?
        let sizes = [data.count]
        let err = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                            dataBuffer: block,
                                            formatDescription: format,
                                            sampleCount: 1,
                                            sampleTimingEntryCount: 1,
                                            sampleTimingArray: &timing,
                                            sampleSizeEntryCount: 1,
                                            sampleSizeArray: sizes,
                                            sampleBufferOut: &sbuf)
        guard err == noErr, let s = sbuf else {
            throw NSError(domain: "VT", code: Int(err))
        }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]
        var outFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: s, flags: flags, frameRefcon: nil, infoFlagsOut: &outFlags)
    }

    func finish() {
        VTDecompressionSessionFinishDelayedFrames(session!)
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
    }

    func invalidate() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
    }
}

// MARK: - Data helpers

private extension Data {
    func uint16BE(at i: Int) -> UInt16 {
        let a = self[i]; let b = self[i+1]
        return (UInt16(a) << 8) | UInt16(b)
    }
    func uint24BE(at i: Int) -> UInt32 {
        let a = UInt32(self[i]); let b = UInt32(self[i+1]); let c = UInt32(self[i+2])
        return (a << 16) | (b << 8) | c
    }
    func uint32BE(at i: Int) -> UInt32 {
        let a = UInt32(self[i]); let b = UInt32(self[i+1]); let c = UInt32(self[i+2]); let d = UInt32(self[i+3])
        return (a << 24) | (b << 16) | (c << 8) | d
    }
    func uint64BE(at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(self[i+k]) }
        return v
    }
    func fourCC(at i: Int) -> String {
        String(bytes: self[i..<i+4], encoding: .ascii) ?? "????"
    }
}
