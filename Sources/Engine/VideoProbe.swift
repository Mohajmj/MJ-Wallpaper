import Foundation
import AVFoundation

struct VideoInfo {
    var name: String
    var duration: Double      // seconds (same role as ffprobe format=duration)
    var width: Int            // display width (after preferredTransform)
    var height: Int
    var fps: Double
    var sizeBytes: Int64
}

enum EngineError: Error, LocalizedError {
    case noVideoTrack, noFrames, readerFailed(String), template(String), validation(String), cancelled
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track"
        case .noFrames: return "No video frames extracted"
        case .readerFailed(let s): return "Reader failed: " + s
        case .template(let s): return s
        case .validation(let s): return "Final archive validation failed: " + s
        case .cancelled: return "Cancelled"
        }
    }
}

enum VideoProbe {
    static func info(url: URL) throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw EngineError.noVideoTrack }
        let size = track.naturalSize.applying(track.preferredTransform)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return VideoInfo(
            name: url.lastPathComponent,
            duration: CMTimeGetSeconds(asset.duration),
            width: Int(abs(size.width).rounded()),
            height: Int(abs(size.height).rounded()),
            fps: Double(track.nominalFrameRate),
            sizeBytes: (attrs?[.size] as? NSNumber)?.int64Value ?? 0)
    }
}
