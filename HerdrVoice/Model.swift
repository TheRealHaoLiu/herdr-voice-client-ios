// Everything the screen shows and everything a hold, a typed line or a tap sets off.
// A thin client: the server decides what a turn is; this file follows server.ts's replies the way
// the Mac app (herdr-voice/mac) does, with speech done on the phone.
//
// One voice at a time: only the session that is open on screen speaks. What any other session says
// is kept in its conversation as unread, counted in the inbox, and played when you open it.
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

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

struct Line: Identifiable, Equatable {
    enum Who { case me, agent, note, problem }
    let id = UUID()
    let who: Who
    var text: String
    var at: Double = nowMs() // when it was said, in milliseconds
    var unread = false       // an agent's line that has not been played on this phone yet
    var live = true          // arrived while the app was running: its time is the phone's clock, not the server's
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
    @Published var target: String? // the session open on screen; nil while the inbox is showing
    @Published var lines: [String: [Line]] = [:]
    @Published var asks: [String: Ask] = [:]
    @Published var pending: Set<String> = [] { didSet { UIApplication.shared.isIdleTimerDisabled = !pending.isEmpty } }
    @Published var phase = Phase.idle
    @Published var liveWords = ""
    @Published var hearing = Loading.no
    @Published var kokoro = Loading.no
    @Published var banner: String?
    @Published var speaking = false
    @Published var voice: Voice { didSet { defaults.set(voice.rawValue, forKey: "voice"); if voice == .kokoro { Task { await loadKokoro() } } } }
    @Published var kokoroVoice: String { didSet { defaults.set(kokoroVoice, forKey: "kokoroVoice") } }
    /// Per session: the time of the newest line already played on this phone. Kept across launches,
    /// so what an agent said while the app was closed can be told apart from what was heard.
    private var heardUpTo: [String: Double] { didSet { defaults.set(heardUpTo, forKey: "heardUpTo") } }

    init() {
        voice = Voice(rawValue: defaults.string(forKey: "voice") ?? "") ?? .phone
        kokoroVoice = defaults.string(forKey: "kokoroVoice") ?? "am_echo"
        heardUpTo = (defaults.dictionary(forKey: "heardUpTo") as? [String: Double]) ?? [:]
        speaker.finished = { [weak self] in self?.speaking = false; self?.playNext() }
    }

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
        waiting.removeAll(); speaker.stop()
        Store.forget()
        paired = false; started = false; target = nil
        sessions = []; lines = [:]; asks = [:]; pending = []
    }

    func refreshSessions() async {
        let r: [String: Any]
        do { r = try await api.call("/api/sessions", timeout: 8) } catch { serverUp = false; serverWhy = error.localizedDescription; return }
        guard let list = r["sessions"] as? [[String: Any]] else { serverUp = false; serverWhy = (r["error"] as? String) ?? "The server sent something unreadable."; return }
        serverUp = true
        sessions = list.compactMap(Session.init)
        // Each session's recent history is read once, which is also how missed lines are found.
        for s in sessions where lines[s.address] == nil { await loadHistory(s.address) }
    }

    private func loadHistory(_ t: String) async {
        guard let r = try? await api.call("/api/history" + API.query(t) + "&limit=30", timeout: 15) else { return } // tried again next time
        let known = heardUpTo[t]
        if known == nil { heardUpTo[t] = nowMs() } // a session seen for the first time has nothing missed
        let old: [Line] = ((r["items"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let text = item["text"] as? String else { return nil }
            let at = (item["at"] as? Double) ?? 0
            switch item["who"] as? String {
            case "me": return Line(who: .me, text: text, at: at, live: false)
            case "agent":
                // The server marks an agent speaking up unasked with `from`. One of those, newer than
                // the last thing played here, was missed. Replies to turns asked from other devices
                // carry no `from` and are not counted: they were heard there.
                let missed = item["from"] != nil && known.map { at > $0 } == true
                return Line(who: .agent, text: text, at: at, unread: missed, live: false)
            default: return Line(who: .note, text: text, at: at, live: false)
            }
        }
        lines[t] = old + (lines[t] ?? [])
    }

    // MARK: the inbox

    func unread(_ t: String) -> Int { lines[t]?.reduce(0) { $0 + ($1.unread ? 1 : 0) } ?? 0 }
    func lastLine(_ t: String) -> Line? { lines[t]?.last { $0.who == .agent || $0.who == .me } }
    /// Sessions that have something for you first, then the server's order (most recently active first).
    var inbox: [Session] {
        sessions.enumerated().sorted { a, b in
            let wa = unread(a.element.address) > 0 || a.element.status == "blocked", wb = unread(b.element.address) > 0 || b.element.status == "blocked"
            return wa != wb ? wa : a.offset < b.offset
        }.map(\.element)
    }

    /// A session comes on screen: it becomes the one that speaks, and what you missed from it is played.
    func open(_ t: String) {
        if target != t { waiting.removeAll(); if speaker.busy { speaker.stop() } }
        target = t
        Task {
            if lines[t] == nil { await loadHistory(t) }
            guard target == t else { return }
            playMissed(t)
            // A session already stopped on a prompt: show it again, as a reloaded page does.
            if let r = try? await api.call("/api/screen" + API.query(t), timeout: 15), let ask = Ask(r["ask"]) { asks[t] = ask }
        }
    }

    /// Back to the inbox: nothing speaks. Lines not played yet stay unread for the next visit.
    func close(_ t: String) {
        guard target == t else { return }
        cancelHold()
        target = nil
        waiting.removeAll()
        if speaker.busy { speaker.stop() }
    }

    private func playMissed(_ t: String) {
        for line in lines[t] ?? [] where line.unread && !waiting.contains(where: { $0.line == line.id }) {
            waiting.append(Utterance(words: line.text, clip: nil, line: line.id, session: t))
        }
        playNext()
    }

    /// Say a line again.
    func replay(_ line: Line, in t: String) {
        guard phase == .idle else { return }
        waiting.insert(Utterance(words: line.text, clip: nil, line: line.id, session: t), at: 0)
        if speaker.busy { speaker.stop() } else { playNext() } // stopping moves on to the next in line, which is this one
    }

    func markAllHeard(_ t: String) {
        for i in (lines[t] ?? []).indices { lines[t]![i].unread = false }
        heardUpTo[t] = nowMs()
        if t == target { hush() }
    }

    /// Stop talking and drop what was waiting to be said; all of it counts as heard.
    func hush() {
        for u in waiting { if let id = u.line { heard(id, in: u.session) } }
        waiting.removeAll()
        if speaker.busy { speaker.stop() }
    }

    private func heard(_ id: UUID, in t: String) {
        guard let i = lines[t]?.firstIndex(where: { $0.id == id }) else { return }
        lines[t]![i].unread = false
        let line = lines[t]![i]
        // A live line's time is this phone's clock; two seconds of slack keep the server's copy of the
        // same line from counting as missed at the next launch if the clocks differ a little.
        heardUpTo[t] = max(heardUpTo[t] ?? 0, line.at + (line.live ? 2000 : 0))
    }

    // MARK: what is on screen

    @discardableResult
    private func add(_ who: Line.Who, _ text: String, to t: String?, unread: Bool = false) -> UUID? {
        guard let t, !text.isEmpty else { if who == .problem { flash(text) }; return nil }
        let line = Line(who: who, text: text, unread: unread)
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
        guard target != nil else { return }
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

    /// Leaving the conversation mid-hold: the recording is thrown away.
    private func cancelHold() {
        wantRecording = false
        liveTask?.cancel(); liveTask = nil
        if phase == .recording { _ = recorder.stop() }
        if phase != .hearing { phase = .idle; liveWords = "" }
    }

    func sendTyped(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let t = target else { return }
        Task { await send(words, to: t, spoken: false) }
    }

    // MARK: a turn

    private func send(_ text: String, to t: String, spoken: Bool) async {
        if t == target { hush() } // you have answered the session that was speaking: the rest of it is dropped
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

    /// Puts one reply from the server on screen and, for the open session, in the speech queue.
    /// True if it gave the user anything.
    @discardableResult
    private func show(_ r: [String: Any], from t: String) -> Bool {
        var gave = (r["narrated"] as? Bool) == true || (r["command"] as? Bool) == true
        let ask = Ask(r["ask"])
        if let note = r["note"] as? String, !note.isEmpty { add(.note, note, to: t); gave = true }
        if let words = r["spoken"] as? String, !words.isEmpty {
            deliver(words, clip: (r["audio"] as? String).flatMap { Data(base64Encoded: $0) }, to: t); gave = true
        }
        if let ask {
            asks[t] = ask; gave = true
            let clip = ((r["ask"] as? [String: Any])?["audio"] as? String).flatMap { Data(base64Encoded: $0) }
            if t != target { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            else if !ask.say.isEmpty { waiting.append(Utterance(words: ask.say, clip: clip, line: nil, session: t)); playNext() }
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
        hush()
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

    private struct Utterance { let words: String; let clip: Data?; let line: UUID?; let session: String }
    private var waiting: [Utterance] = []
    private var preparing = false

    /// An agent's words arriving. They are shown in its session. If that session is the open one they
    /// are spoken; otherwise they wait there as unread, with a tap on the wrist instead of a voice.
    private func deliver(_ words: String, clip: Data?, to t: String) {
        guard let id = add(.agent, words, to: t, unread: true) else { return }
        if t == target { waiting.append(Utterance(words: words, clip: clip, line: id, session: t)); playNext() }
        else { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    private func playNext() {
        guard phase == .idle, !speaker.busy, !preparing, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        if let id = next.line { heard(id, in: next.session) } // a line counts as heard once it starts playing
        speaking = true
        switch voice {
        case .phone: speaker.say(next.words)
        case .mac: if let clip = next.clip { speaker.play(clip: clip) } else { speaker.say(next.words) }
        case .kokoro:
            guard kokoro == .ready else { speaker.say(next.words); return }
            preparing = true
            Task {
                let clip = try? await LocalSpeech.shared.speak(next.words, voice: kokoroVoice)
                preparing = false
                guard phase == .idle, target == next.session else { speaking = false; return } // you started talking, or left, meanwhile
                if let clip { speaker.play(clip: clip) } else { speaker.say(next.words) }
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
                let body = (item["text"] as? String) ?? ""
                guard !body.isEmpty, let t = (item["address"] as? String) ?? target else { continue }
                let clip = (item["audio"] as? String).flatMap { Data(base64Encoded: $0) }
                // play:false means another of your devices is the one saying it: shown here, already heard there.
                if (item["kind"] as? String) != "progress", (item["play"] as? Bool) == false { add(.agent, body, to: t); continue }
                deliver(body, clip: clip, to: t)
            }
        }
    }
}
