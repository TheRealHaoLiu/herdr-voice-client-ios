import SwiftUI
import VisionKit

@main
struct HerdrVoiceApp: App {
    @StateObject private var model = Model.shared
    @Environment(\.scenePhase) private var scene
    var body: some Scene {
        WindowGroup {
            Group { if model.paired { MainView() } else { PairView() } }
                .environmentObject(model)
                .onAppear { model.start() }
                .onChange(of: scene) { _, now in if now == .active, model.paired { Task { await model.refreshSessions() } } }
        }
    }
}

// MARK: pairing

struct PairView: View {
    @EnvironmentObject var model: Model
    @State private var scanning = false
    @State private var link = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform.circle.fill").font(.system(size: 72)).foregroundStyle(.tint)
            Text("Herdr Voice").font(.largeTitle.bold())
            Text("On the Mac, right-click the Herdr Voice button and choose Connect a Phone. Then scan the code it shows.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { scanning = true } label: { Label("Scan the code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(working || !DataScannerViewController.isSupported)
            HStack {
                TextField("or paste the pairing link", text: $link)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Pair") { pair(link) }.disabled(link.isEmpty || working)
            }
            if working { ProgressView("Pairing…") }
            if let problem { Text(problem).foregroundStyle(.red).multilineTextAlignment(.center) }
            Spacer()
        }
        .padding(24)
        .sheet(isPresented: $scanning) {
            QRScanner { code in scanning = false; pair(code) }.ignoresSafeArea()
        }
    }

    private func pair(_ code: String) {
        working = true; problem = nil
        Task { problem = await model.pair(link: code); working = false }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var found: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(found) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        var done = false
        init(_ found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in added {
                guard !done, case .barcode(let code) = item, let text = code.payloadStringValue else { continue }
                done = true; scanner.stopScanning(); found(text)
            }
        }
    }
}

// MARK: talking

struct MainView: View {
    @EnvironmentObject var model: Model
    @State private var typed = ""
    @State private var settings = false
    @FocusState private var typing: Bool

    private var lines: [Line] { model.target.flatMap { model.lines[$0] } ?? [] }
    private var working: Bool { model.target.map { model.pending.contains($0) } ?? false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.serverUp { Notice(text: model.serverWhy.isEmpty ? API.unreachable : model.serverWhy, color: .red) }
                if case .loading = model.hearing { Notice(text: "Loading the speech model… (the first time downloads it)", color: .orange) }
                if case .failed(let why) = model.hearing { Notice(text: "The speech model could not load. \(why)", color: .red) }
                if let banner = model.banner { Notice(text: banner, color: .blue) }
                conversation
                if let t = model.target, let ask = model.asks[t] { AskCard(ask: ask) }
                controls
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { sessionMenu }
                ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "gearshape") } }
            }
            .sheet(isPresented: $settings) { SettingsView() }
        }
    }

    private var sessionMenu: some View {
        Menu {
            let machines = Dictionary(grouping: model.sessions, by: \.machine)
            ForEach(machines.keys.sorted(), id: \.self) { machine in
                Section(machine) {
                    ForEach(machines[machine] ?? []) { s in
                        Button { model.select(s.address) } label: {
                            Label("\(s.label) · \(s.status)", systemImage: s.address == model.target ? "checkmark" : dot(s.status))
                        }
                    }
                }
            }
            if model.sessions.isEmpty { Text("No agent sessions are running.") }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color(model.current?.status ?? "")).frame(width: 9, height: 9)
                Text(model.current?.label ?? "Pick a session").font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }
        }
    }
    private func dot(_ status: String) -> String { status == "working" ? "circle.dotted" : status == "blocked" ? "exclamationmark.circle" : "circle" }
    private func color(_ status: String) -> Color { status == "working" ? .orange : status == "blocked" ? .red : status.isEmpty ? .gray : .green }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(lines) { Bubble(line: $0) }
                    if model.phase != .idle {
                        Bubble(line: Line(who: .me, text: model.liveWords.isEmpty ? (model.phase == .recording ? "Listening…" : "…") : model.liveWords)).opacity(0.6)
                    }
                    if working && model.phase == .idle { HStack(spacing: 8) { ProgressView(); Text("Working…").foregroundStyle(.secondary) } }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
            .onChange(of: model.liveWords) { _, _ in proxy.scrollTo("end") }
            .onChange(of: model.target) { _, _ in proxy.scrollTo("end") }
            .onAppear { proxy.scrollTo("end") }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Type a message or a /command", text: $typed, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($typing)
                    .textInputAutocapitalization(.sentences).onSubmit(sendTyped)
                if !typed.isEmpty { Button(action: sendTyped) { Image(systemName: "arrow.up.circle.fill").font(.title) } }
            }
            HStack(spacing: 28) {
                Button { model.stopTask() } label: { VStack { Image(systemName: "stop.circle").font(.title); Text("Stop").font(.caption) } }
                    .disabled(!working).opacity(working ? 1 : 0.3)
                TalkButton()
                Button { model.sendNow() } label: { VStack { Image(systemName: "bolt.circle").font(.title); Text("Send now").font(.caption) } }
                    .disabled(!working).opacity(working ? 1 : 0.3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
    }

    private func sendTyped() { model.sendTyped(typed); typed = ""; typing = false }
}

/// Hold to talk. The press and the release are the whole control, so it is a gesture, not a button.
struct TalkButton: View {
    @EnvironmentObject var model: Model
    @State private var down = false
    var body: some View {
        let recording = model.phase == .recording
        ZStack {
            Circle().fill(recording ? Color.red : model.hearing == .ready ? Color.accentColor : Color.gray)
                .frame(width: 96, height: 96).scaleEffect(down ? 1.15 : 1).shadow(radius: recording ? 12 : 3)
            Image(systemName: model.phase == .hearing ? "ellipsis" : "mic.fill").font(.system(size: 36, weight: .semibold)).foregroundStyle(.white)
        }
        .animation(.spring(duration: 0.2), value: down)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !down { down = true; model.holdBegan() } }
            .onEnded { _ in down = false; model.holdEnded() })
        .accessibilityLabel("Hold to talk")
    }
}

struct Bubble: View {
    let line: Line
    var body: some View {
        switch line.who {
        case .me: HStack { Spacer(minLength: 40); text.padding(10).background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white) }
        case .agent: HStack { text.padding(10).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14)); Spacer(minLength: 40) }
        case .note: text.font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
        case .problem: text.font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .center)
        }
    }
    private var text: some View { Text(line.text).textSelection(.enabled) }
}

struct AskCard: View {
    @EnvironmentObject var model: Model
    let ask: Ask
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("It is asking for permission", systemImage: "hand.raised.fill").font(.headline)
            Text(ask.what.isEmpty ? ask.text : ask.what).font(.system(.callout, design: .monospaced)).lineLimit(8)
            if ask.can {
                HStack {
                    Button(role: .destructive) { model.answer(allow: false) } label: { Text("Deny").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    Button { model.answer(allow: true) } label: { Text("Allow").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            } else {
                Text("This one can only be answered in Herdr.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

struct Notice: View {
    let text: String, color: Color
    var body: some View {
        Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8).background(color.opacity(0.15))
    }
}

// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Replies are spoken by", selection: $model.voice) { ForEach(Voice.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                    if model.voice == .kokoro {
                        Picker("Voice", selection: $model.kokoroVoice) { ForEach(kokoroVoices, id: \.id) { Text($0.title).tag($0.id) } }
                        switch model.kokoro {
                        case .loading: Label("Loading the voice… (the first time downloads it)", systemImage: "arrow.down.circle")
                        case .failed(let why): Label("The voice could not load. \(why)", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        default: EmptyView()
                        }
                    }
                } header: { Text("Replies are spoken by") } footer: {
                    Text("The iPhone voice starts at once. The Mac's voice sounds the same as on your other devices but takes one more trip to the server. The experimental one runs the Mac's voice engine on this phone; its makers flag it as able to crash the app on this iOS version.")
                }
                Section { Toggle("Agents can speak up by themselves", isOn: $model.announceOn) }
                Section("Server") {
                    LabeledContent("Address", value: Store.server ?? "none")
                    LabeledContent("This phone", value: Store.clientId)
                    Button("Unpair this phone", role: .destructive) { confirmUnpair = true }
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair this phone? The access key is removed from it.", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { model.unpair(); dismiss() }
            }
        }
    }
}
