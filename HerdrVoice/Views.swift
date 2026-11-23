import SwiftUI
import VisionKit

@main
struct HerdrVoiceApp: App {
    @StateObject private var model = Model.shared
    @Environment(\.scenePhase) private var scene
    var body: some Scene {
        WindowGroup {
            Group { if model.paired { InboxView() } else { PairView() } }
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

// MARK: the inbox: every agent session, the ones with something for you first

struct InboxView: View {
    @EnvironmentObject var model: Model
    @State private var settings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Notices()
                List {
                    ForEach(model.inbox) { s in
                        NavigationLink(value: s.address) { InboxRow(session: s) }
                            .swipeActions(edge: .trailing) {
                                if model.unread(s.address) > 0 { Button("Heard") { model.markAllHeard(s.address) }.tint(.blue) }
                            }
                    }
                    if model.sessions.isEmpty {
                        Text(model.serverUp ? "No agent sessions are running." : "Waiting for the voice server…").foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.refreshSessions() }
            }
            .navigationTitle("Agents")
            .navigationDestination(for: String.self) { ConversationView(address: $0) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "gearshape") } } }
            .sheet(isPresented: $settings) { SettingsView() }
        }
    }
}

struct InboxRow: View {
    @EnvironmentObject var model: Model
    let session: Session
    var body: some View {
        let missed = model.unread(session.address), last = model.lastLine(session.address)
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(statusColor(session.status)).frame(width: 10, height: 10).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.label).font(.headline).fontWeight(missed > 0 ? .bold : .semibold).lineLimit(1)
                    Spacer()
                    if let last { Text(Date(timeIntervalSince1970: last.at / 1000).formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                }
                Text([session.machine, session.status].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if let last {
                    Text((last.who == .me ? "You: " : "") + last.text).font(.subheadline).lineLimit(2)
                        .foregroundStyle(missed > 0 ? .primary : .secondary)
                }
            }
            VStack(spacing: 6) {
                if missed > 0 {
                    Text("\(missed)").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.accentColor, in: Capsule())
                }
                if session.status == "blocked" { Image(systemName: "hand.raised.fill").foregroundStyle(.orange) }
            }
        }
        .padding(.vertical, 4)
    }
}

func statusColor(_ status: String) -> Color { status == "working" ? .orange : status == "blocked" ? .red : status.isEmpty ? .gray : .green }

/// What is wrong or still loading, shown on both screens.
struct Notices: View {
    @EnvironmentObject var model: Model
    var body: some View {
        VStack(spacing: 0) {
            if !model.serverUp { Notice(text: model.serverWhy.isEmpty ? API.unreachable : model.serverWhy, color: .red) }
            if case .loading = model.hearing { Notice(text: "Loading the speech model… (the first time downloads it)", color: .orange) }
            if case .failed(let why) = model.hearing { Notice(text: "The speech model could not load. \(why)", color: .red) }
            if let banner = model.banner { Notice(text: banner, color: .blue) }
        }
    }
}

// MARK: one session: talk to it, hear it, play things again

struct ConversationView: View {
    @EnvironmentObject var model: Model
    let address: String
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var session: Session? { model.sessions.first { $0.address == address } }
    private var lines: [Line] { model.lines[address] ?? [] }
    private var working: Bool { model.pending.contains(address) }

    var body: some View {
        VStack(spacing: 0) {
            Notices()
            conversation
            if let ask = model.asks[address] { AskCard(ask: ask) }
            controls
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor(session?.status ?? "")).frame(width: 9, height: 9)
                    Text(session?.label ?? address).font(.headline).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.hush() } label: { Image(systemName: "speaker.slash") }
                    .disabled(!model.speaking).accessibilityLabel("Stop speaking")
            }
        }
        .onAppear { model.open(address) }
        .onDisappear { model.close(address) }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(lines) { line in Bubble(line: line) { model.replay(line, in: address) } }
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

/// One line of the conversation. Tapping something an agent said plays it again.
struct Bubble: View {
    let line: Line
    var replay: (() -> Void)? = nil
    var body: some View {
        switch line.who {
        case .me: HStack { Spacer(minLength: 40); text.padding(10).background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white) }
        case .agent:
            HStack(alignment: .top, spacing: 6) {
                text.padding(10).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    .onTapGesture { replay?() }
                    .accessibilityHint("Plays it again")
                if line.unread { Circle().fill(Color.accentColor).frame(width: 9, height: 9).padding(.top, 8) }
                Spacer(minLength: 30)
            }
        case .note: text.font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
        case .problem: text.font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .center)
        }
    }
    private var text: some View { Text(line.text) }
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
                    Text("The iPhone voice starts at once. The Mac's voice sounds the same as on your other devices but takes one more trip to the server; things played again use the iPhone voice. The experimental one runs the Mac's voice engine on this phone; its makers flag it as able to crash the app on this iOS version.")
                }
                Section {
                    LabeledContent("Address", value: Store.server ?? "none")
                    LabeledContent("This phone", value: Store.clientId)
                    Button("Unpair this phone", role: .destructive) { confirmUnpair = true }
                } header: { Text("Server") } footer: {
                    Text("Only the session you have open speaks. What other sessions say waits in the list as unread and plays when you open them.")
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
