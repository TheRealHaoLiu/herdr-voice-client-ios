// Speech on this phone. Speech-to-text is Parakeet through FluidAudio, the same engine the Mac app
// uses. Text-to-speech has three sources (see Voice): the phone's built-in voice, Kokoro on the
// phone, or a clip made by the Mac.
import AVFoundation
import FluidAudio
import Foundation

/// Where the spoken reply comes from.
enum Voice: String, CaseIterable, Identifiable {
    case phone   // the iPhone's built-in voice: starts at once, needs nothing downloaded
    case mac     // the server sends a clip in the Mac's voice: same voice as everywhere else, one more round trip
    case kokoro  // the Mac's voice engine on the phone: FluidAudio flags it as crash-prone on iOS 26.4 and later
    var id: String { rawValue }
    var title: String {
        switch self {
        case .phone: return "iPhone voice"
        case .mac: return "Mac's voice (from the server)"
        case .kokoro: return "Mac's voice on this phone (experimental)"
        }
    }
}

let kokoroVoices: [(title: String, id: String)] = [
    ("Echo (American, male)", "am_echo"), ("Liam (American, male)", "am_liam"), ("Puck (American, male)", "am_puck"),
    ("Eric (American, male)", "am_eric"), ("Michael (American, male, deep)", "am_michael"),
    ("George (British, male)", "bm_george"), ("Fable (British, male)", "bm_fable"), ("Heart (American, female)", "af_heart"),
]

actor LocalSpeech {
    static let shared = LocalSpeech()
    private var asr: AsrManager?
    private var tts: KokoroAneManager?

    /// Loads the speech-to-text model; the first time downloads it.
    func prepareHearing() async throws {
        guard asr == nil else { return }
        let models = try await AsrModels.downloadAndLoad()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    func prepareKokoro(voice: String) async throws {
        guard tts == nil else { return }
        let kokoro = KokoroAneManager(version: .v3)
        try await kokoro.initialize(preloadVoices: [voice])
        tts = kokoro
    }

    /// 16 kHz mono samples in, words out.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let asr else { throw VoiceError(message: "The speech model is not loaded yet.") }
        var audio = samples
        if audio.count < 16000 { audio += [Float](repeating: 0, count: 16000 - audio.count) } // the model wants a second at least
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns WAV data ready for AVAudioPlayer.
    func speak(_ text: String, voice: String) async throws -> Data {
        guard let tts else { throw VoiceError(message: "Kokoro is not loaded yet.") }
        return try await tts.synthesize(text: text, voice: voice)
    }
}

/// The microphone, as 16 kHz mono samples that can be read while the recording is still going.
final class Recorder {
    static let rate = 16000.0
    static let longest = Int(rate) * 120 // a hold stops counting at two minutes
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recorder.rate, channels: 1, interleaved: false)!

    var soFar: [Float] { lock.lock(); defer { lock.unlock() }; return samples }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError(message: "The microphone is not available.") }
        converter = AVAudioConverter(from: format, to: target)
        lock.lock(); samples = []; lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.add(buffer) }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return soFar
    }

    private func add(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let room = AVAudioFrameCount(Double(buffer.frameLength) * Recorder.rate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: room) else { return }
        var given = false
        var problem: NSError?
        converter.convert(to: out, error: &problem) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buffer
        }
        guard problem == nil, out.frameLength > 0, let channel = out.floatChannelData else { return }
        let chunk = UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
        lock.lock()
        if samples.count < Recorder.longest { samples.append(contentsOf: chunk) }
        lock.unlock()
    }
}

/// Says one thing at a time: either a clip (WAV data) or words in the phone's built-in voice.
@MainActor
final class Speaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private(set) var busy = false
    private(set) var paused = false
    var finished: () -> Void = {}

    override init() { super.init(); synth.delegate = self }

    static let phoneVoice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return english.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    func play(clip: Data) {
        guard let p = try? AVAudioPlayer(data: clip) else { finished(); return }
        player = p; p.delegate = self; busy = true; paused = false
        p.play()
    }

    func say(_ words: String) {
        let u = AVSpeechUtterance(string: words)
        u.voice = Speaker.phoneVoice
        busy = true; paused = false
        synth.speak(u)
    }

    func pause() {
        guard busy, !paused else { return }
        if let p = player, p.isPlaying { p.pause(); paused = true }
        else if synth.isSpeaking { synth.pauseSpeaking(at: .immediate); paused = true }
    }

    func resume() {
        guard paused else { return }
        paused = false
        if let p = player { p.play() } else { synth.continueSpeaking() }
    }

    func stop() {
        let was = busy
        busy = false; paused = false
        player?.stop(); player = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        if was { finished() }
    }

    private func done() {
        guard busy else { return } // stop() has already said so
        busy = false; paused = false; player = nil
        finished()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully ok: Bool) { Task { @MainActor in self.done() } }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Task { @MainActor in self.done() } }
}
