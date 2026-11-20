// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import AVFoundation
import CoreImage

enum TextVideoStyle: String, CaseIterable, Identifiable, Sendable {
    case fullWidth = "全角灰度 26×7", blocks = "方块", halfBlocks = "半格方块（实验）"
    var id: String { rawValue }
    var firstCellPadding: String { "\u{3000}" }

    static var alignmentRuler: String {
        let runs = [String(repeating: "█", count: 24), String(repeating: "\u{3000}", count: 24),
                    String(repeating: "Ｉ", count: 24), String(repeating: "Ｗ", count: 24),
                    String(repeating: "０１", count: 12), String(repeating: "．：＋＃％＠", count: 4),
                    String(repeating: "＠\u{3000}", count: 12)]
        return runs.map { "｜" + $0 + "｜" }.joined(separator: "\n")
    }
}

struct TextVideoFrame: Sendable {
    let seconds: Double
    let pixels: [UInt8]

    func text(style: TextVideoStyle, inverted: Bool, enhanceContrast: Bool = false) -> String {
        let samples: [UInt8]
        if enhanceContrast, let low = pixels.min(), let high = pixels.max(), high > low {
            samples = pixels.map { UInt8((Int($0) - Int(low)) * 255 / (Int(high) - Int(low))) }
        } else { samples = pixels }
        if style == .fullWidth {
            return FullWidthBrightnessPalette.render(samples, inverted: inverted)
        }
        var rows: [String] = []
        for row in 0..<7 {
            var line = ""
            for column in 0..<26 {
                if style == .blocks {
                    var brightness = 0
                    for y in 0..<4 { for x in 0..<2 { brightness += Int(samples[(row * 4 + y) * 52 + column * 2 + x]) } }
                    let white = brightness >= 128 * 8
                    line += (inverted ? !white : white) ? "█" : "\u{3000}"
                } else if style == .halfBlocks {
                    func half(_ offset: Int) -> Bool {
                        var brightness = 0
                        for y in 0..<2 { for x in 0..<2 { brightness += Int(samples[(row * 4 + offset + y) * 52 + column * 2 + x]) } }
                        let white = brightness >= 128 * 4
                        return inverted ? !white : white
                    }
                    switch (half(0), half(2)) {
                    case (true, true): line += "█"
                    case (true, false): line += "▀"
                    case (false, true): line += "▄"
                    case (false, false): line += "\u{3000}"
                    }
                }
            }
            rows.append(line)
        }
        return rows.joined(separator: "\n")
    }
}

struct TextVideo: Sendable {
    let name: String
    let frames: [TextVideoFrame]
    let duration: Double

    static func targetViewport(sourceWidth: Double, sourceHeight: Double, preserveAspectRatio: Bool) -> CGRect {
        guard preserveAspectRatio, sourceWidth > 0, sourceHeight > 0 else {
            return CGRect(x: 0, y: 0, width: 52, height: 28)
        }
        let canvasCellAspect = 26.0 / 7.0
        let sourceAspect = sourceWidth / sourceHeight
        let fitCellsW: Double
        let fitCellsH: Double
        if sourceAspect >= canvasCellAspect {
            fitCellsW = 26.0
            fitCellsH = 26.0 / sourceAspect
        } else {
            fitCellsH = 7.0
            fitCellsW = 7.0 * sourceAspect
        }
        let drawW = max(1.0, min(52.0, (fitCellsW * 2.0).rounded()))
        let drawH = max(1.0, min(28.0, (fitCellsH * 4.0).rounded()))
        let offsetX = ((52.0 - drawW) / 2.0).rounded(.down)
        let offsetY = ((28.0 - drawH) / 2.0).rounded(.down)
        return CGRect(x: offsetX, y: offsetY, width: drawW, height: drawH)
    }

    static func load(_ url: URL, preserveAspectRatio: Bool = false) async throws -> TextVideo {
        let worker = Task.detached(priority: .userInitiated) { () throws -> TextVideo in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(domain: "TextVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件没有可读取的视频轨道。"])
            }
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            guard duration.isFinite, duration > 0, duration <= 600 else {
                throw NSError(domain: "TextVideo", code: 2, userInfo: [NSLocalizedDescriptionKey: "请选择不超过 10 分钟的本地视频。"])
            }
            let transform = try await track.load(.preferredTransform)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? NSError(domain: "TextVideo", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法启动视频解码。"])
            }
            defer { reader.cancelReading() }
            let context = CIContext(options: [.cacheIntermediates: false])
            let colorSpace = CGColorSpaceCreateDeviceGray()
            let canvasBounds = CGRect(x: 0, y: 0, width: 52, height: 28)
            let blackBackdrop = CIImage(color: .black).cropped(to: canvasBounds)
            var frames: [TextVideoFrame] = []
            var nextTime = 0.0
            var firstTime: Double?
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                if firstTime == nil { firstTime = timestamp }
                let seconds = max(0, timestamp - (firstTime ?? timestamp))
                guard seconds + 0.0001 >= nextTime, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pixels: [UInt8] = autoreleasepool {
                    let image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                    let origin = image.extent.origin
                    let viewport = Self.targetViewport(
                        sourceWidth: image.extent.width,
                        sourceHeight: image.extent.height,
                        preserveAspectRatio: preserveAspectRatio
                    )
                    let verticalScale = viewport.height / image.extent.height
                    let scaled = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
                        .clampedToExtent()
                        .applyingFilter("CILanczosScaleTransform", parameters: [
                            kCIInputScaleKey: verticalScale,
                            kCIInputAspectRatioKey: (viewport.width / image.extent.width) / verticalScale
                        ])
                        .cropped(to: CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height))
                    let composed: CIImage
                    if preserveAspectRatio {
                        composed = scaled
                            .transformed(by: CGAffineTransform(translationX: viewport.origin.x, y: viewport.origin.y))
                            .composited(over: blackBackdrop)
                            .cropped(to: canvasBounds)
                    } else {
                        composed = scaled
                    }
                    var pixels = [UInt8](repeating: 0, count: 52 * 28)
                    pixels.withUnsafeMutableBytes {
                        context.render(composed, toBitmap: $0.baseAddress!, rowBytes: 52, bounds: canvasBounds, format: .L8, colorSpace: colorSpace)
                    }
                    return pixels
                }
                frames.append(TextVideoFrame(seconds: seconds, pixels: pixels))
                nextTime = (floor((seconds + 0.0001) * 10) + 1) / 10
            }
            try Task.checkCancellation()
            if reader.status == .failed { throw reader.error ?? NSError(domain: "TextVideo", code: 3) }
            guard !frames.isEmpty else { throw NSError(domain: "TextVideo", code: 4, userInfo: [NSLocalizedDescriptionKey: "未能解码视频画面。"] ) }
            return TextVideo(name: url.lastPathComponent, frames: frames, duration: max(duration, frames.last!.seconds + 0.1))
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
