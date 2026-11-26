import SwiftUI
import UniformTypeIdentifiers

private func T(_ k: String) -> Text { Text(Loc.t(k)) }

struct RootView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        TabView {
            LibraryView().tabItem { Image(systemName: "film.stack"); T("tab.library") }
            CreateView().tabItem { Image(systemName: "wand.and.stars"); T("tab.create") }
            ReportsView().tabItem { Image(systemName: "doc.text.magnifyingglass"); T("tab.reports") }
            SettingsView().tabItem { Image(systemName: "gearshape"); T("tab.settings") }
        }
        .id(store.language)   // refresh strings when language changes
    }
}

func infoRows(_ i: VideoInfo) -> [(String, String)] {
    [("info.name", i.name), ("info.duration", String(format: "%.2f s", i.duration)),
     ("info.resolution", "\(i.width) × \(i.height)"), ("info.fps", String(format: "%.2f FPS", i.fps)),
     ("info.size", String(format: "%.2f MB", Double(i.sizeBytes) / 1_048_576))]
}

struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var showPhotos = false, showFiles = false
    @State private var infoURL: URL?
    var body: some View {
        NavigationView {
            Group {
                if store.videos.isEmpty {
                    VStack(spacing: 12) { Image(systemName: "video.badge.plus").font(.system(size: 48)).foregroundColor(.secondary)
                        T("lib.empty").multilineTextAlignment(.center).foregroundColor(.secondary) }.padding()
                } else {
                    List {
                        ForEach(store.videos, id: \.self) { v in
                            Button { infoURL = v } label: {
                                HStack { Image(systemName: "film"); VStack(alignment: .leading) {
                                    Text(v.lastPathComponent).lineLimit(1)
                                    if let i = try? VideoProbe.info(url: v) {
                                        Text(String(format: "%.1fs • %dx%d", i.duration, i.width, i.height)).font(.caption).foregroundColor(.secondary) } } }
                            }.foregroundColor(.primary)
                        }.onDelete { idx in idx.map { store.videos[$0] }.forEach(store.delete) }
                    }.listStyle(InsetGroupedListStyle())
                }
            }
            .navigationTitle(Loc.t("tab.library"))
            .toolbar { Menu { Button { showPhotos = true } label: { Label(Loc.t("lib.photos"), systemImage: "photo") }
                              Button { showFiles = true } label: { Label(Loc.t("lib.files"), systemImage: "folder") }
            } label: { Image(systemName: "plus.circle.fill") } }
            .sheet(isPresented: $showPhotos) { PhotoVideoPicker { store.importFile($0, into: store.libraryDir) } }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data]) { r in
                if case .success(let u) = r { store.importFile(u, into: store.libraryDir) } }
            .sheet(item: Binding(get: { infoURL.map { IdentURL(url: $0) } }, set: { infoURL = $0?.url })) { item in
                VideoInfoSheet(url: item.url)
            }
        }.navigationViewStyle(StackNavigationViewStyle())
    }
}
struct IdentURL: Identifiable { let url: URL; var id: String { url.path } }

struct VideoInfoSheet: View {
    let url: URL
    var body: some View {
        NavigationView {
            List {
                if let i = try? VideoProbe.info(url: url) {
                    ForEach(infoRows(i), id: \.0) { r in HStack { T(r.0); Spacer(); Text(r.1).foregroundColor(.secondary) } }
                }
            }.navigationTitle(Loc.t("lib.info"))
        }
    }
}

final class CancelFlag { var value = false }

struct CreateView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: URL?
    @State private var name = ""
    @State private var running = false
    @State private var percent = 0
    @State private var stageKey = "stage.analyze"
    @State private var result: BuildReport?
    @State private var resultURL: URL?
    @State private var errorText: String?
    @State private var share = false
    @State private var cancel = CancelFlag()

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker(Loc.t("create.select"), selection: $selected) {
                        Text("—").tag(URL?.none)
                        ForEach(store.videos, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                    }
                    if let s = selected, let i = try? VideoProbe.info(url: s) {
                        ForEach(infoRows(i), id: \.0) { r in HStack { T(r.0); Spacer(); Text(r.1).foregroundColor(.secondary) } }
                    }
                }
                Section {
                    TextField(Loc.t("create.name"), text: $name).disableAutocorrection(true)
                    Picker(Loc.t("create.template"), selection: $store.selectedTemplate) {
                        Text(Loc.t("settings.template.default")).tag("builtin")
                        ForEach(store.templates, id: \.self) { Text($0.lastPathComponent).tag($0.lastPathComponent) }
                    }
                }
                Section {
                    if running {
                        VStack(alignment: .leading, spacing: 8) {
                            T(stageKey).font(.subheadline)
                            ProgressView(value: Double(percent), total: 100)
                            Text("\(percent)%").font(.caption).foregroundColor(.secondary)
                        }
                        Button { cancel.value = true } label: { T("create.cancel") }
                    } else {
                        Button(action: start) { HStack { Spacer(); T("create.start").bold(); Spacer() } }
                            .disabled(selected == nil)
                    }
                }
                if let e = errorText { Section { Text(e).foregroundColor(.red) } }
                if let r = result {
                    Section(header: T("result.ok")) {
                        row("result.frames", "\(r.frames)"); row("result.refs", "\(r.refs)")
                        row("result.missing", "\(r.missing)"); row("result.zip", r.zipOK ? Loc.t("status.ok") : Loc.t("status.fail"))
                        Button { share = true } label: { Label(Loc.t("result.share"), systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle(Loc.t("tab.create"))
            .sheet(isPresented: $share) { if let u = resultURL { ShareSheet(items: [u]) } }
        }.navigationViewStyle(StackNavigationViewStyle())
    }

    private func row(_ k: String, _ v: String) -> some View { HStack { T(k); Spacer(); Text(v).foregroundColor(.secondary) } }

    private func start() {
        guard let video = selected, let template = store.templateURL() else { errorText = "Template missing"; return }
        let out = store.uniqueOutput(name.isEmpty ? video.deletingPathExtension().lastPathComponent : name)
        running = true; percent = 0; result = nil; errorText = nil
        cancel = CancelFlag(); let flag = cancel
        let began = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let b = TendiesBuilder(); b.isCancelled = { flag.value }
            do {
                let r = try b.build(video: video, template: template, output: out) { p, _, key in
                    DispatchQueue.main.async { percent = p; stageKey = key } }
                let final = store.deliver(out)
                store.record(video: video, output: final, ok: true, report: r, elapsed: Date().timeIntervalSince(began))
                DispatchQueue.main.async { result = r; resultURL = out; running = false }
            } catch {
                try? FileManager.default.removeItem(at: out)
                store.logError("build \(video.lastPathComponent): \(error)")
                store.record(video: video, output: out, ok: false, report: nil, elapsed: Date().timeIntervalSince(began))
                DispatchQueue.main.async { errorText = error.localizedDescription; running = false }
            }
        }
    }
}

struct ReportsView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab = 0
    @State private var confirmClear = false
    var body: some View {
        NavigationView {
            VStack {
                Picker("", selection: $tab) { T("reports.archive").tag(0); T("reports.history").tag(1) }
                    .pickerStyle(SegmentedPickerStyle()).padding(.horizontal)
                if (tab == 0 ? store.reports.isEmpty : store.history.isEmpty) {
                    Spacer(); T("reports.empty").foregroundColor(.secondary); Spacer()
                } else if tab == 0 {
                    List(store.reports) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(r.date) \(r.time) • \(r.video)").font(.headline)
                            Text(r.report).font(.system(.caption, design: .monospaced))
                        }
                    }
                } else {
                    List(store.history) { h in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text("\(h.date) \(h.time)").font(.subheadline); Spacer()
                                Text(Loc.t(h.status == "ok" ? "status.ok" : "status.fail")).foregroundColor(h.status == "ok" ? .green : .red) }
                            Text(h.video).font(.headline)
                            Text(String(format: "%@ → %d • %.2fs", (h.output as NSString).lastPathComponent, h.frames, h.elapsed))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(Loc.t("tab.reports"))
            .toolbar { Button { confirmClear = true } label: { Image(systemName: "trash") } }
            .alert(isPresented: $confirmClear) {
                Alert(title: T("common.confirm"), primaryButton: .destructive(T("reports.clear")) {
                    store.clear(tab == 0 ? store.reportsURL : store.historyURL) }, secondaryButton: .cancel(T("common.cancel")))
            }
        }.navigationViewStyle(StackNavigationViewStyle())
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showFolder = false, showTemplate = false
    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker(Loc.t("settings.language"), selection: $store.language) {
                        T("lang.system").tag("system"); T("lang.ar").tag("ar"); T("lang.en").tag("en") }
                    Picker(Loc.t("settings.appearance"), selection: $store.appearance) {
                        T("appearance.system").tag("system"); T("appearance.light").tag("light"); T("appearance.dark").tag("dark") }
                }
                Section(header: T("settings.output")) {
                    Text(store.customOutputName ?? Loc.t("settings.output.default")).foregroundColor(.secondary)
                    Button { showFolder = true } label: { T("settings.output.choose") }
                    if store.customOutputName != nil { Button { store.resetOutputFolder() } label: { T("settings.output.default") } }
                }
                Section(header: T("settings.templates")) {
                    Picker(Loc.t("create.template"), selection: $store.selectedTemplate) {
                        Text(Loc.t("settings.template.default")).tag("builtin")
                        ForEach(store.templates, id: \.self) { Text($0.lastPathComponent).tag($0.lastPathComponent) } }
                    Button { showTemplate = true } label: { T("settings.template.import") }
                    ForEach(store.templates, id: \.self) { Text($0.lastPathComponent) }
                        .onDelete { idx in idx.map { store.templates[$0] }.forEach(store.delete) }
                }
                Section(header: T("settings.errors")) {
                    NavigationLink(destination: ErrorLogView()) { T("settings.errors") }
                    Button { store.clear(store.errorsURL) } label: { T("settings.errors.clear") }
                }
                Section { NavigationLink(destination: AboutView()) { T("about.title") } }
            }
            .navigationTitle(Loc.t("tab.settings"))
            .sheet(isPresented: $showFolder) { FolderPicker { store.setOutputFolder($0); showFolder = false } }
            .fileImporter(isPresented: $showTemplate, allowedContentTypes: [.data]) { r in
                if case .success(let u) = r { store.importFile(u, into: store.templatesDir) } }
        }.navigationViewStyle(StackNavigationViewStyle())
    }
}

struct ErrorLogView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ScrollView { Text((try? String(contentsOf: store.errorsURL, encoding: .utf8)) ?? "—")
            .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle(Loc.t("settings.errors"))
    }
}

struct AboutView: View {
    var body: some View {
        List {
            HStack { T("about.app"); Spacer(); Text("MJ Wallpaper").foregroundColor(.secondary) }
            HStack { T("about.dev"); Spacer(); Text("@hamade_jmj").foregroundColor(.secondary) }
            Link(destination: URL(string: "https://x.com/hamade_jmj")!) {
                HStack { T("about.x"); Spacer(); Text("x.com/hamade_jmj") } }
            T("about.privacy").font(.footnote).foregroundColor(.secondary)
        }.navigationTitle(Loc.t("about.title"))
    }
}
