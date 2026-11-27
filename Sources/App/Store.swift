import Foundation
import SwiftUI

enum Loc {
    static var lang = "system"   // system | ar | en
    static func t(_ key: String) -> String {
        var code = lang
        if code == "system" { code = (Locale.preferredLanguages.first ?? "en").hasPrefix("ar") ? "ar" : "en" }
        if let p = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: p) {
            return b.localizedString(forKey: key, value: key, table: nil)
        }
        return key
    }
}

struct HistoryRecord: Codable, Identifiable {
    var id = UUID()
    var date: String, time: String, video: String, output: String, status: String
    var duration: Double = 0, frames: Int = 0, elapsed: Double = 0
}
struct ReportRecord: Codable, Identifiable {
    var id = UUID()
    var date: String, time: String, video: String, output: String, report: String
}

final class AppStore: ObservableObject {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let libraryDir = docs.appendingPathComponent("MJ-Library")
    let outputDir = docs.appendingPathComponent("MJ-Wallpapers")
    let historyURL = docs.appendingPathComponent("MJ-History.jsonl")
    let reportsURL = docs.appendingPathComponent("MJ-Reports.jsonl")
    let errorsURL = docs.appendingPathComponent("MJ-Errors.log")
    private let ud = UserDefaults.standard

    @Published var videos: [URL] = []
    @Published var history: [HistoryRecord] = []
    @Published var reports: [ReportRecord] = []
    @Published var language: String { didSet { ud.set(language, forKey: "lang"); Loc.lang = language } }
    @Published var appearance: String { didSet { ud.set(appearance, forKey: "appearance") } }
    @Published var customOutputName: String? = nil

    init() {
        language = ud.string(forKey: "lang") ?? "system"
        appearance = ud.string(forKey: "appearance") ?? "system"
        Loc.lang = language
        for d in [libraryDir, outputDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        if let b = ud.data(forKey: "outputBookmark"), let u = resolveBookmark(b) { customOutputName = u.lastPathComponent }
        reload()
    }

    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    var isArabic: Bool { language == "ar" || (language == "system" && (Locale.preferredLanguages.first ?? "").hasPrefix("ar")) }

    // MARK: library
    func reload() {
        let exts = ["mp4", "mov", "m4v", "mkv", "avi"]
        videos = list(libraryDir).filter { exts.contains($0.pathExtension.lowercased()) }
        history = readJSONL(historyURL, HistoryRecord.self).reversed()
        reports = readJSONL(reportsURL, ReportRecord.self).reversed()
    }
    private func list(_ d: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func importFile(_ src: URL, into dir: URL) {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        var dst = dir.appendingPathComponent(src.lastPathComponent)
        var n = 1
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + "-\(n)." + src.pathExtension); n += 1
        }
        do { try FileManager.default.copyItem(at: src, to: dst) } catch { logError("import: \(error)") }
        DispatchQueue.main.async { self.reload() }
    }
    func delete(_ u: URL) { try? FileManager.default.removeItem(at: u); reload() }
    func templateURL() -> URL? {
        Bundle.main.url(forResource: "Video-B-anim", withExtension: "tendies")
    }

    // MARK: output folder (security-scoped bookmark)
    func setOutputFolder(_ u: URL) {
        let access = u.startAccessingSecurityScopedResource()
        defer { if access { u.stopAccessingSecurityScopedResource() } }
        do {
            let b = try u.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            ud.set(b, forKey: "outputBookmark")
            customOutputName = u.lastPathComponent
            logError("setOutputFolder: saved bookmark for \(u.lastPathComponent)")
        } catch {
            logError("setOutputFolder failed: \(error)")
        }
    }
    func resetOutputFolder() { ud.removeObject(forKey: "outputBookmark"); customOutputName = nil }
    private func resolveBookmark(_ b: Data) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: b,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            logError("bookmark: resolution failed")
            return nil
        }
        if stale {
            logError("bookmark: stale; refresh deferred until folder access")
        }
        return url
    }

    func deliver(_ file: URL) -> (url: URL, error: String?) {
        guard let b = ud.data(forKey: "outputBookmark") else {
            logError("deliver: no output folder selected; kept internally")
            return (file, nil)
        }
        guard let folder = resolveBookmark(b) else {
            logError("deliver: invalid output folder bookmark")
            return (file, "Output folder save failed")
        }

        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let refreshed = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            ud.set(refreshed, forKey: "outputBookmark")
            logError("bookmark: refreshed during folder access")
        } catch {
            logError("bookmark: refresh failed: \(error)")
        }

        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var destination = folder.appendingPathComponent(file.lastPathComponent)
        var n = 1

        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            destination = folder.appendingPathComponent(name)
            n += 1
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyError: Error?
        var finalURL = destination

        coordinator.coordinate(
            writingItemAt: destination,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            finalURL = coordinatedURL
            do {
                try FileManager.default.copyItem(at: file, to: coordinatedURL)
            } catch {
                copyError = error
            }
        }

        if let error = coordinationError {
            logError("deliver: coordination failed: \(error)")
            return (file, "Output folder save failed")
        }
        if let error = copyError {
            logError("deliver: copy failed: \(error)")
            return (file, "Output folder save failed")
        }

        guard FileManager.default.fileExists(atPath: finalURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else {
            logError("deliver: verification failed for \(finalURL.path)")
            return (file, "Output folder save failed")
        }

        logError("deliver: verified copy \(finalURL.path), \(size) bytes")
        return (finalURL, nil)
    }
    func uniqueOutput(_ name: String) -> URL {
        let clean = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined().trimmingCharacters(in: .whitespaces)
        let base = clean.isEmpty ? "MJ-Wallpaper" : clean
        var u = outputDir.appendingPathComponent(base + ".tendies"); var n = 1
        while FileManager.default.fileExists(atPath: u.path) { u = outputDir.appendingPathComponent("\(base)-\(n).tendies"); n += 1 }
        return u
    }

    // MARK: history / reports / errors
    private func stamp() -> (String, String) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; let d = f.string(from: Date()); f.dateFormat = "HH:mm:ss"; return (d, f.string(from: Date()))
    }
    func record(video: URL, output: URL, ok: Bool, report: BuildReport?, elapsed: Double) {
        let (d, t) = stamp()
        append(HistoryRecord(date: d, time: t, video: video.lastPathComponent, output: output.path, status: ok ? "ok" : "fail",
                             duration: Double(report?.duration ?? "0") ?? 0, frames: report?.frames ?? 0, elapsed: elapsed), to: historyURL)
        if let r = report { append(ReportRecord(date: d, time: t, video: video.lastPathComponent, output: output.path, report: r.text), to: reportsURL) }
        DispatchQueue.main.async { self.reload() }
    }
    func logError(_ s: String) {
        let (d, t) = stamp()
        let line = "[\(d) \(t)] \(s)\n"
        if let h = try? FileHandle(forWritingTo: errorsURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { try? line.write(to: errorsURL, atomically: true, encoding: .utf8) }
    }
    func clear(_ u: URL) { try? Data().write(to: u); reload() }
    private func append<T: Encodable>(_ v: T, to u: URL) {
        guard var data = try? JSONEncoder().encode(v) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(data); h.closeFile() } else { try? data.write(to: u) }
    }
    private func readJSONL<T: Decodable>(_ u: URL, _ t: T.Type) -> [T] {
        guard let s = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
}
