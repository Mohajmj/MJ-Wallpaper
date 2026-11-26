import SwiftUI

@main
struct MJWallpaperApp: App {
    @StateObject private var store = AppStore()

    init() {
        // CI self-test hook: MJWallpaper --selftest <video> <template> <output>
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--selftest"), a.count > i + 3 {
            do {
                let b = TendiesBuilder()
                let r = try b.build(video: URL(fileURLWithPath: a[i + 1]), template: URL(fileURLWithPath: a[i + 2]),
                                    output: URL(fileURLWithPath: a[i + 3])) { _, _, _ in }
                print("SELFTEST OK frames=\(r.frames) refs=\(r.refs) missing=\(r.missing) duration=\(r.duration)")
                exit(0)
            } catch { print("SELFTEST FAIL: \(error)"); exit(1) }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
                .environment(\.layoutDirection, store.isArabic ? .rightToLeft : .leftToRight)
                .preferredColorScheme(store.colorScheme)
        }
    }
}
