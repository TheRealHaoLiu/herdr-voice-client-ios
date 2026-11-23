// Everything the screen shows and everything a hold, a typed line or a tap sets off.
// A thin client: the server decides what a turn is; this file follows server.ts's replies the way
// the Mac app (herdr-voice/mac) does, with speech done on the phone.
import AVFoundation
import SwiftUI
import UIKit

struct Session: Identifiable, Equatable {
    let address: String, machine: String, label: String, status: String
    var id: String { address }
    init?(_ s: [String: Any]) {
        guard let a = s["address"] as? String else { return nil }
        address = a
        machine = (s["machine"] as? String) ?? ""
        let folder = (s["folder"] as? String) ?? ""
        label = (s["name"] as? String) ?? (s["title"] as? String) ?? (folder.isEmpty ? a : folder)
        status = (s["status"] as? String) ?? ""
    }
}

struct Line: Identifiable, Equatable {
    enum Who { case me, agent, note, problem }
    let id = UUID()
    let who: Who
    var text: String
}

/// A permission prompt a session has stopped on.
struct Ask: Equatable {
    let text: String, what: String, can: Bool, say: String
    init?(_ any: Any?) {
        guard let a = any as? [String: Any] else { return nil }
        text = (a["text"] as? String) ?? "It is asking for permission."
        what = (a["what"] as? String) ?? ""
        can = (a["can"] as? Bool) ?? false
        say = (a["say"] as? String) ?? ""
    }
}

enum Phase { case idle, recording, hearing }
enum Loading: Equatable { case no, loading, ready, failed(String) }

@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    private let api = API()
    private let recorder = Recorder()
    private let speaker = Speaker()
    private let defaults = UserDefaults.standard

    @Published var paired = Store.paired
    @Published var sessions: [Session] = []
    @Published var serverUp = true
    @Published var serverWhy = "" // why the last call to the server failed
    @Published var target: String? { didSet { defaults.set(target, forKey: "session") } }
    @Published var lines: [String: [Line]] = [:]
    @Published var asks: [String: Ask] = [:]
    @Published var pending: Set<String> = [] { didSet { UIApplication.shared.isIdleTimerDisabled = !pending.isEmpty } }
    @Published var phase = Phase.idle
    @Published var liveWords = ""
    @Published var hearing = Loading.no
    @Published var kokoro = Loading.no
    @Published var banner: String?
    @Published var voice: Voice { didSet { defaults.set(voice.rawValue, forKey: "voice"); if voice == .kokoro { Task { await loadKokoro() } } } }
    @Published var kokoroVoice: String { didSet { defaults.set(kokoroVoice, forKey: "kokoroVoice") } }
    @Published var announceOn: Bool { didSet { defaults.set(!announceOn, forKey: "announceOff") } }

    init() {
        target = defaults.string(forKey: "session")
        voice = Voice(rawValue: defaults.string(forKey: "voice") ?? "") ?? .phone
        kokoroVoice = defaults.string(forKey: "kokoroVoice") ?? "am_echo"
        announceOn = !defaults.bool(forKey: "announceOff")
        speaker.finished = { [weak self] in self?.speakingFrom = nil; self?.playNext() }
    }

    var current: Session? { sessions.first { $0.address == target } }
    func name(_ t: String) -> String { sessions.first { $0.address == t }?.label ?? t }
    /// A client that voices replies itself tells the server not to make a clip.
    private var noClip: String { voice == .mac ? "" : "&audio=0" }
    private func json(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }

    // MARK: start, pair, sessions

    private var started = false
    func start() {
        guard paired, !started else { return }
        started = true
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
        Task { await loadHearing() }
        if voice == .kokoro { Task { await loadKokoro() } }
        Task { while paired { await refreshSessions(); try? await Task.sleep(nanoseconds: 5_000_000_000) } }
        Task { await listenForAnnouncements() }
    }

    func pair(link: String) async -> String? {
        do { try await API.pair(link: link) } catch { return error.localizedDescription }
        paired = true; started = false
        start()
        return nil
    }

    func unpair() {
        speaker.stop(); waiting.removeAll()
        Store.forget()
        paired = false; started = false
        sessions = []; lines = [:]; asks = [:]; pending = []
    }

    func refreshSessions() async {
        let r: [String: Any]
        do { r = try await api.call("/api/sessions", timeout: 8) } catch { serverUp = false; serverWhy = error.localizedDescription; return }
        guard let list = r["sessions"] as? [[String: Any]] else { serverUp = false; serverWhy = (r["error"] as? String) ?? "The server sent something unreadable."; return }
        serverUp = true
        sessions = list.compactMap(Session.init)
        if target == nil || !sessions.contains(where: { $0.address == target }) {
            if let first = sessions.first?.address { select(first) }
        } else if let t = target, lines[t] == nil { select(t) }
    }

    func select(_ t: String) {
        target = t
        Task {
            if lines[t] == nil { await loadHistory(t) }
            // A session already stopped on a prompt: show it again, as a reloaded page does.
            if let r = try? await api.call("/api/screen" + API.query(t), timeout: 15), let ask = Ask(r["ask"]) { asks[t] = ask }
        }
    }

    private func loadHistory(_ t: String) async {
        guard let r = try? await api.call("/api/history" + API.query(t) + "&limit=30", timeout: 15) else { return }
        let old: [Line] = ((r["items"] as? [[String: Any]]) ?? []).compactMap {
            guard let text = $0["text"] as? String else { return nil }
            switch $0["who"] as? String { case "me": return Line(who: .me, text: text); case "agent": return Line(who: .agent, text: text); default: return Line(who: .note, text: text) }
        }
        lines[t] = old + (lines[t] ?? [])
    }

    // MARK: what is on screen

    @discardableResult
    private func add(_ who: Line.Who, _ text: String, to t: String?) -> UUID? {
        guard let t, !text.isEmpty else { if who == .problem { flash(text) }; return nil }
        let line = Line(who: who, text: text)
        lines[t, default: []].append(line)
        if lines[t]!.count > 200 { lines[t]!.removeFirst(lines[t]!.count - 200) }
        return line.id
    }

    private var bannerTask: Task<Void, Never>?
    func flash(_ text: String, seconds: Double = 5) {
        guard !text.isEmpty else { return }
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); if !Task.isCancelled { banner = nil } }
    }

    // MARK: speech models

    func loadHearing() async {
        guard hearing == .no || { if case .failed = hearing { return true }; return false }() else { return }
        hearing = .loading
        do { try await LocalSpeech.shared.prepareHearing(); hearing = .ready }
        catch { hearing = .failed(error.localizedDescription) }
    }

    func loadKokoro() async {
        guard kokoro == .no || { if case .failed = kokoro { return true }; return false }() else { return }
        kokoro = .loading
        do { try await LocalSpeech.shared.prepareKokoro(voice: kokoroVoice); kokoro = .ready }
        catch { kokoro = .failed(error.localizedDescription) }
    }

    // MARK: hold to talk

    private var wantRecording = false
    private var liveTask: Task<Void, Never>?

    func holdBegan() {
        guard phase == .idle, !wantRecording else { return }
        guard hearing == .ready else { flash(hearing == .loading ? "The speech model is still loading." : "The speech model is not loaded."); return }
        guard target != nil else { flash("Pick a session first."); return }
        wantRecording = true
        speaker.pause() // talking pauses whatever is being said
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                wantRecording = false; speaker.resume()
                flash("Microphone access is off for Herdr Voice (Settings, Privacy, Microphone).", seconds: 8); return
            }
            guard wantRecording else { speaker.resume(); return } // let go before the recorder could start
            do { try recorder.start() } catch { wantRecording = false; speaker.resume(); flash(error.localizedDescription); return }
            phase = .recording; liveWords = ""
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            liveTask = Task { await self.showWordsWhileTalking() }
        }
    }

    /// The words so far, heard again from the start each time: often at first, less often as the clip grows.
    private func showWordsWhileTalking() async {
        while !Task.isCancelled, phase == .recording {
            let seconds = Double(recorder.soFar.count) / Recorder.rate
            try? await Task.sleep(nanoseconds: UInt64(max(0.7, seconds / 5) * 1e9))
            guard !Task.isCancelled, phase == .recording else { return }
            let clip = recorder.soFar
            guard clip.count > 8000 else { continue }
            if let words = try? await LocalSpeech.shared.transcribe(clip), !Task.isCancelled, phase == .recording { liveWords = words }
        }
    }

    func holdEnded() {
        wantRecording = false
        guard phase == .recording else { return }
        let clip = recorder.stop()
        let live = liveTask; liveTask = nil; live?.cancel()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard clip.count > Int(0.4 * Recorder.rate), let t = target else {
            phase = .idle; liveWords = ""; speaker.resume(); playNext()
            flash("Too short. Hold while you talk.", seconds: 3); return
        }
        phase = .hearing
        Task {
            await live?.value // never two transcriptions at once
            let said = try? await LocalSpeech.shared.transcribe(clip)
            phase = .idle; liveWords = ""
            guard let said, !said.isEmpty else { speaker.resume(); playNext(); flash("I didn't catch anything."); return }
            await send(said, to: t, spoken: true)
        }
    }

    func sendTyped(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let t = target else { return }
        Task { await send(words, to: t, spoken: false) }
    }

    // MARK: a turn

    private func send(_ text: String, to t: String, spoken: Bool) async {
        // You have answered the session that was speaking: drop the rest of what it was saying.
        if speakingFrom == t { waiting.removeAll { $0.from == t }; speaker.stop() } else { speaker.resume(); playNext() }
        let mine = add(.me, text, to: t)
        let wasPending = pending.contains(t)
        pending.insert(t)
        defer { if !wasPending { pending.remove(t) } }
        do {
            var r = try await api.call("/api/say" + API.query(t) + noClip + (spoken ? "&spoken=1" : ""), method: "POST",
                                       body: json(["text": text]), type: "application/json")
            if let heard = r["heard"] as? String, !heard.isEmpty, heard != text, let mine,
               let i = lines[t]?.firstIndex(where: { $0.id == mine }) { lines[t]![i].text = heard }
            if (r["steered"] as? Bool) == true { add(.note, "Sent while it works: it reads this at its next step.", to: t); return }
            var said = false
            while true {
                if show(r, from: t) { said = true }
                guard (r["status"] as? String) == "working" else { break }
                r = try await api.call("/api/collect" + API.query(t) + noClip, method: "POST")
            }
            if !said { add(.note, "Finished without saying anything.", to: t) }
        } catch { add(.problem, error.localizedDescription, to: t) }
        await refreshSessions()
    }

    /// Puts one reply from the server on screen and in the speech queue. True if it gave the user anything.
    @discardableResult
    private func show(_ r: [String: Any], from t: String) -> Bool {
        var gave = (r["narrated"] as? Bool) == true || (r["command"] as? Bool) == true
        let ask = Ask(r["ask"])
        if let note = r["note"] as? String, !note.isEmpty { add(.note, note, to: t); gave = true }
        if let words = r["spoken"] as? String, !words.isEmpty {
            add(.agent, words, to: t); gave = true
            speak(words, clip: (r["audio"] as? String).flatMap { Data(base64Encoded: $0) }, from: t)
        }
        if let ask {
            asks[t] = ask; gave = true
            let clip = ((r["ask"] as? [String: Any])?["audio"] as? String).flatMap { Data(base64Encoded: $0) }
            if !ask.say.isEmpty { speak(ask.say, clip: clip, from: t) }
        } else if let problem = r["error"] as? String, !problem.isEmpty { add(.problem, problem, to: t); gave = true }
        return gave
    }

    func answer(allow: Bool) {
        guard let t = target, let ask = asks[t] else { return }
        Task {
            do {
                let r = try await api.call("/api/answer" + API.query(t) + "&choice=" + (allow ? "allow" : "deny") + noClip, method: "POST",
                                           body: json(["what": ask.what]), type: "application/json", timeout: 60)
                if (r["changed"] as? Bool) == true, let new = Ask(r["ask"]) { asks[t] = new; add(.note, "That request was replaced by a new one.", to: t); return }
                asks[t] = nil
                guard (r["answered"] as? Bool) == true else { add(.problem, (r["error"] as? String) ?? "Could not answer it.", to: t); return }
                add(.note, (allow ? "Allowed: " : "Denied: ") + (ask.what.isEmpty ? "the request" : ask.what), to: t)
                if allow { await follow(t) } // the task goes on: keep listening to it
            } catch { add(.problem, error.localizedDescription, to: t) }
        }
    }

    private func follow(_ t: String) async {
        pending.insert(t); defer { pending.remove(t) }
        do {
            var r: [String: Any]
            repeat { r = try await api.call("/api/collect" + API.query(t) + noClip, method: "POST"); show(r, from: t) } while (r["status"] as? String) == "working"
        } catch { add(.problem, error.localizedDescription, to: t) }
        await refreshSessions()
    }

    func stopTask() {
        guard let t = target else { return }
        waiting.removeAll { $0.from == t }
        if speakingFrom == t { speaker.stop() }
        Task {
            let r = try? await api.call("/api/stop" + API.query(t), method: "POST", timeout: 30)
            add(.note, (r?["stopped"] as? Bool) == true ? "Stopped." : "Could not stop it.", to: t)
            await refreshSessions()
        }
    }

    func sendNow() {
        guard let t = target else { return }
        Task {
            let r = try? await api.call("/api/now" + API.query(t), method: "POST", timeout: 30)
            if (r?["sent"] as? Bool) != true { flash((r?["error"] as? String) ?? "Could not send it now.") }
        }
    }

    // MARK: saying things, one at a time

    private struct Utterance { let words: String; let clip: Data?; let from: String? }
    private var waiting: [Utterance] = []
    private var speakingFrom: String?
    private var preparing = false

    private func speak(_ words: String, clip: Data?, from: String?) {
        waiting.append(Utterance(words: words, clip: clip, from: from))
        playNext()
    }

    private func playNext() {
        guard phase == .idle, !speaker.busy, !preparing, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        speakingFrom = next.from
        // Several sessions can be working at once: a line from one that is not on screen is named first.
        let words = next.from.flatMap { $0 != target ? "From \(name($0)). \(next.words)" : nil } ?? next.words
        switch voice {
        case .phone: speaker.say(words)
        case .mac: if let clip = next.clip { speaker.play(clip: clip) } else { speaker.say(words) }
        case .kokoro:
            guard kokoro == .ready else { speaker.say(words); return }
            preparing = true
            Task {
                let clip = try? await LocalSpeech.shared.speak(words, voice: kokoroVoice)
                preparing = false
                guard phase == .idle else { waiting.insert(next, at: 0); speakingFrom = nil; return } // you started talking meanwhile
                if let clip { speaker.play(clip: clip) } else { speaker.say(words) }
            }
        }
    }

    // MARK: agents speaking up by themselves

    private func listenForAnnouncements() async {
        var last = -1, epoch = 0.0
        while paired {
            guard let r = try? await api.call("/api/announcements?after=\(last)&wait=25" + noClip, timeout: 45) else {
                try? await Task.sleep(nanoseconds: 3_000_000_000); continue
            }
            let e = (r["epoch"] as? Double) ?? 0
            // First call: start from now. Server restarted (its numbering began again): take everything since.
            if last < 0 || e != epoch { last = (epoch != 0 && e != epoch) ? 0 : ((r["last"] as? Int) ?? 0); epoch = e; continue }
            for item in (r["items"] as? [[String: Any]]) ?? [] {
                last = max(last, (item["id"] as? Int) ?? last)
                let body = (item["text"] as? String) ?? "", address = item["address"] as? String
                let clip = (item["audio"] as? String).flatMap { Data(base64Encoded: $0) }
                guard !body.isEmpty else { continue }
                if (item["kind"] as? String) == "progress" { // narration during a turn asked from this phone
                    add(.agent, body, to: address ?? target)
                    speak(body, clip: clip, from: address)
                    continue
                }
                guard announceOn else { continue }
                let who = (item["from"] as? String) ?? "an agent"
                add(.agent, body, to: address ?? target)
                if address != target { flash("From \(who): \(body)", seconds: 8) }
                if (item["play"] as? Bool) != false { speak("From \(who). \(body)", clip: clip, from: nil) } // another device may be the one saying it
            }
        }
    }
}
