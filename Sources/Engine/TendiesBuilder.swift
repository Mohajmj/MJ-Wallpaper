import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

/// Native port of MJ V2 `build()`. Same pipeline & output structure:
/// analyse -> extract frames (cover-scale + centre-crop to 468x1013, last row dropped = 468x1012,
/// exactly what ffmpeg's JPEG output produced for ll.tendies) -> rewrite template main.caml
/// (<values> block + animation duration) -> append frames as STORED assets/N.jpg -> validate -> report.
struct BuildReport {
    var outputPath: String, videoPath: String
    var videoWidth: Int, videoHeight: Int
    var fps: String, duration: String
    var frames: Int, refs: Int, missing: Int
    var zipOK: Bool
    var timings: [(String, Double)]

    /// Same layout as the Arabic report written by mj-v2.py.
    var text: String {
        var s = "تقرير إنشاء الخلفية - MJ\n========================\n"
        s += "ملف الخلفية: \(outputPath)\nالفيديو المصدر: \(videoPath)\n"
        s += "أبعاد الفيديو الأصلي: \(videoWidth)x\(videoHeight)\n"
        s += "أبعاد الخلفية: \(TendiesBuilder.targetW)x\(TendiesBuilder.targetH)\n"
        s += "معدل الإطارات: \(fps)\nالمدة: \(duration)\nعدد الإطارات: \(frames)\n"
        s += "مراجع الحركة: \(refs)\nالمراجع المفقودة: \(missing)\n"
        s += "نتيجة فحص الأرشيف: \(zipOK ? "سليم" : "تالف")\nالقالب الأصلي: دون تعديل\n\nأوقات مراحل التنفيذ\n"
        for (k, v) in timings { s += "\(k): \(String(format: "%.2f", v)) ثانية\n" }
        return s
    }
}

final class TendiesBuilder {
    static let targetW = 468
    static let targetH = 1013          // value used by the scale filter / reported size
    static let frameH = 1012           // real JPEG height ffmpeg produced (odd row dropped)
    static let jpegQuality: CGFloat = 0.92

    /// progress(overallPercent 0...100, stageIndex 1...5, stageKey)
    typealias Progress = (Int, Int, String) -> Void
    var isCancelled: () -> Bool = { false }

    static func formatDuration(_ d: Double) -> String {
        var s = String(format: "%.6f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    func build(video: URL, template: URL, output: URL, progress: @escaping Progress) throws -> BuildReport {
        let started = Date()
        var timings: [(String, Double)] = []
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1/5 analyse
        progress(1, 1, "stage.analyze")
        var t = Date()
        let info = try VideoProbe.info(url: video)
        let durationStr = TendiesBuilder.formatDuration(info.duration)
        timings.append(("تحليل الفيديو", Date().timeIntervalSince(t)))
        progress(10, 1, "stage.analyze")

        // 2/5 extract
        t = Date()
        let framesDir = work.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        let count = try extractFrames(video: video, info: info, to: framesDir) { frac in
            progress(10 + Int(frac * 55), 2, "stage.extract")
        }
        if count == 0 { throw EngineError.noFrames }
        timings.append(("استخراج الإطارات", Date().timeIntervalSince(t)))

        // 3/5 build archive
        progress(65, 3, "stage.build")
        t = Date()
        let base = try ZipReader(url: template)
        guard let bp = base.entries.first(where: { $0.name.contains("Background") && $0.name.hasSuffix("main.caml") }) else {
            throw EngineError.template("Background main.caml not found in template")
        }
        let assetDir = String(bp.name[..<bp.name.range(of: "/", options: .backwards)!.upperBound]) + "assets/"
        var caml = String(decoding: try base.data(bp), as: UTF8.self)

        let values = (0..<count).map { "                  <CGImage src=\"assets/\($0).jpg\"/>" }.joined(separator: "\n")
        let valuesRe = try NSRegularExpression(pattern: "<values>.*?</values>", options: [.dotMatchesLineSeparators])
        guard let m1 = valuesRe.firstMatch(in: caml, range: NSRange(caml.startIndex..., in: caml)),
              let r1 = Range(m1.range, in: caml) else { throw EngineError.template("Animation values block not found") }
        caml.replaceSubrange(r1, with: "<values>\n" + values + "\n            </values>")

        let durRe = try NSRegularExpression(pattern: "(<animation\\b[^>]*\\bduration=\")[^\"]+(\")")
        guard let m2 = durRe.firstMatch(in: caml, range: NSRange(caml.startIndex..., in: caml)),
              let g1 = Range(m2.range(at: 1), in: caml), let g2 = Range(m2.range(at: 2), in: caml) else {
            throw EngineError.template("Animation duration not found")
        }
        caml.replaceSubrange(g1.lowerBound..<g2.upperBound, with: String(caml[g1]) + durationStr + String(caml[g2]))
        progress(67, 3, "stage.build")

        try? FileManager.default.removeItem(at: output)
        let out = try ZipWriter(url: output)
        let total = base.entries.count + count
        var done = 0
        for e in base.entries {
            if e.name.hasPrefix(assetDir) && e.name.lowercased().hasSuffix(".jpg") { done += 1; continue }
            if e.name == bp.name { out.replace(e, with: Array(caml.utf8)) } else { out.copy(e, from: base) }
            done += 1
            progress(65 + Int(Double(done) / Double(max(total, 1)) * 20), 3, "stage.build")
            if isCancelled() { out.finish(); throw EngineError.cancelled }
        }
        for i in 0..<count {
            let d = try Data(contentsOf: framesDir.appendingPathComponent("\(i).jpg"))
            out.addStored(name: assetDir + "\(i).jpg", data: [UInt8](d))
            done += 1
            progress(65 + Int(Double(done) / Double(max(total, 1)) * 20), 3, "stage.build")
            if isCancelled() { out.finish(); throw EngineError.cancelled }
        }
        out.finish()
        timings.append(("بناء الأرشيف", Date().timeIntervalSince(t)))

        // 4/5 validate
        progress(85, 4, "stage.validate")
        t = Date()
        let z = try ZipReader(url: output)
        let bad = z.testZip()
        guard let fe = z.entry(named: bp.name) else { throw EngineError.validation("main.caml missing") }
        let finalCaml = String(decoding: try z.data(fe), as: UTF8.self)
        let refRe = try NSRegularExpression(pattern: "<CGImage src=\"([^\"]+)\"")
        let refs: [String] = refRe.matches(in: finalCaml, range: NSRange(finalCaml.startIndex..., in: finalCaml)).compactMap {
            Range($0.range(at: 1), in: finalCaml).map { String(finalCaml[$0]) }
        }
        let names = Set(z.entries.map { $0.name })
        let missing = refs.filter { !names.contains(assetDir + $0.replacingOccurrences(of: "assets/", with: "")) }
        if bad != nil || !missing.isEmpty || refs.count != count {
            throw EngineError.validation("bad=\(bad ?? "none") missing=\(missing.count) refs=\(refs.count) frames=\(count)")
        }
        timings.append(("فحص الخلفية", Date().timeIntervalSince(t)))
        progress(97, 4, "stage.validate")
        timings.append(("الوقت الإجمالي", Date().timeIntervalSince(started)))
        progress(100, 5, "stage.done")

        return BuildReport(outputPath: output.path, videoPath: video.path,
                           videoWidth: info.width, videoHeight: info.height,
                           fps: String(format: "%.2f", info.fps), duration: durationStr,
                           frames: count, refs: refs.count, missing: missing.count,
                           zipOK: bad == nil, timings: timings)
    }

    // MARK: frame extraction

    private func extractFrames(video: URL, info: VideoInfo, to dir: URL, progress: (Double) -> Void) throws -> Int {
        let asset = AVURLAsset(url: video)
        guard let track = asset.tracks(withMediaType: .video).first else { throw EngineError.noVideoTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw EngineError.readerFailed(reader.error?.localizedDescription ?? "?") }

        let T = track.preferredTransform
        let nat = track.naturalSize
        let disp = nat.applying(T)
        let dw = abs(disp.width), dh = abs(disp.height)
        let W = CGFloat(TendiesBuilder.targetW), H = CGFloat(TendiesBuilder.targetH), outH = CGFloat(TendiesBuilder.frameH)
        let s = max(W / dw, H / dh)                         // force_original_aspect_ratio=increase
        let sw = dw * s, sh = dh * s
        let ox = (sw - W) / 2, oyTop = (sh - H) / 2          // centre crop
        let flipRaw = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: nat.height)
        let flipDisp = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: dh)
        let toContext = flipRaw.concatenating(T).concatenating(flipDisp)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: -ox, y: outH + oyTop - sh))

        let cs = CGColorSpaceCreateDeviceRGB()
        var index = 0
        let total = max(info.duration, 0.001)
        while true {
            if isCancelled() { reader.cancelReading(); throw EngineError.cancelled }
            var failure: Error?
            try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer(), let px = CMSampleBufferGetImageBuffer(sample) else { return }
                CVPixelBufferLockBaseAddress(px, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
                let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
                let bi: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                guard let src = CGContext(data: CVPixelBufferGetBaseAddress(px), width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(px), space: cs, bitmapInfo: bi),
                      let raw = src.makeImage(),
                      let dst = CGContext(data: nil, width: TendiesBuilder.targetW, height: TendiesBuilder.frameH,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    failure = EngineError.readerFailed("context"); return
                }
                dst.interpolationQuality = .high
                dst.concatenate(toContext)
                dst.draw(raw, in: CGRect(x: 0, y: 0, width: nat.width, height: nat.height))
                guard let img = dst.makeImage() else { failure = EngineError.readerFailed("image"); return }
                let url = dir.appendingPathComponent("\(index).jpg")
                guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
                    failure = EngineError.readerFailed("jpeg"); return
                }
                CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: TendiesBuilder.jpegQuality] as CFDictionary)
                if !CGImageDestinationFinalize(d) { failure = EngineError.readerFailed("jpeg"); return }
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                progress(min(1, max(0, pts / total)))
                index += 1
            }
            if let f = failure { throw f }
            if reader.status != .reading { break }
        }
        if reader.status == .failed { throw EngineError.readerFailed(reader.error?.localizedDescription ?? "?") }
        return index
    }
}
