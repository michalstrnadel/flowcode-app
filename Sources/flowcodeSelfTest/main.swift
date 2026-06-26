//
//  flowcode-selftest — runnable verification of the flowcodeKit IPC layer.
//
//  XCTest is unavailable under the Command Line Tools (it ships with Xcode), so the
//  Phase 1 verification lives in this small executable. It checks (1) the NDJSON wire
//  contract decode/encode against the exact bytes the Python status_broadcaster uses,
//  and (2) a live AF_UNIX loopback: server -> IPCClient -> VoiceSessionStore mapping,
//  plus the app -> server control (send) path. Exits non-zero on any failure.
//
//  Run: swift run flowcode-selftest
//

import Foundation
import Darwin
import Metal
import simd
import flowcodeKit

// MARK: - tiny check harness

final class Checks: @unchecked Sendable {
    var failures = 0
    func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ok  \(msg)") } else { failures += 1; print("  FAIL \(msg)") }
    }
}
let checks = Checks()

// MARK: - minimal AF_UNIX test server

final class UnixSocketTestServer: @unchecked Sendable {
    let path: String
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "selftest.unixserver")
    private let accepted = DispatchSemaphore(value: 0)

    init(path: String) { self.path = path }

    func start() -> Bool {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        guard cpath.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            cpath.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bindRes == 0, listen(listenFD, 1) == 0 else { return false }
        acceptQueue.async { [self] in
            let c = accept(listenFD, nil, nil)
            if c >= 0 {
                var tv = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            }
            clientFD = c
            accepted.signal()
        }
        return true
    }

    func waitForClient(timeout: Double) -> Bool {
        accepted.wait(timeout: .now() + timeout) == .success && clientFD >= 0
    }

    func send(_ jsonObject: String) {
        let bytes = Array((jsonObject + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
    }

    func recv() -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(clientFD, &buf, buf.count)
        guard n > 0 else { return "" }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }

    func stop() {
        if clientFD >= 0 { close(clientFD) }
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }
}

// MARK: - wire contract checks

func wireChecks() {
    print("== wire contract ==")
    let dec = JSONDecoder()
    do {
        let m = try dec.decode(StatusMessage.self, from: Data(
            #"{"type":"event","event_type":"TTS_PLAYBACK_START","session_id":"s","ts":"t","state":"speaking"}"#.utf8))
        checks.check(m.type == "event" && m.eventType == "TTS_PLAYBACK_START"
                     && m.state == .speaking && m.sessionId == "s", "decode event + state=speaking")

        let amp = try dec.decode(StatusMessage.self, from: Data(#"{"type":"amplitude","rms":0.42}"#.utf8))
        checks.check(amp.type == "amplitude" && amp.rms == 0.42 && amp.state == nil, "decode amplitude frame")

        let weird = try dec.decode(StatusMessage.self, from: Data(#"{"type":"event","state":"teleporting"}"#.utf8))
        checks.check(weird.state == nil, "unknown state -> nil (forward-compatible)")

        let minimal = try dec.decode(StatusMessage.self, from: Data(#"{"type":"event","event_type":"RECORDING_START"}"#.utf8))
        checks.check(minimal.eventType == "RECORDING_START" && minimal.state == nil, "missing optional keys tolerated")
    } catch {
        checks.check(false, "decode threw: \(error)")
    }

    func line(_ c: ControlCommand) -> String { String(data: c.jsonLine(), encoding: .utf8) ?? "" }
    checks.check(line(.start) == "{\"cmd\":\"start\"}\n", "encode start")
    checks.check(line(.stop) == "{\"cmd\":\"stop\"}\n", "encode stop")
    checks.check(line(.setFlag(key: "VOICEMODE_BARGEIN_ENABLED", value: "true"))
                 == "{\"cmd\":\"set_flag\",\"key\":\"VOICEMODE_BARGEIN_ENABLED\",\"value\":\"true\"}\n", "encode set_flag")
    checks.check(line(.confirm(id: "abc", verdict: "allow"))
                 == "{\"cmd\":\"confirm\",\"id\":\"abc\",\"verdict\":\"allow\"}\n", "encode confirm")
}

// MARK: - live IPC loopback

@MainActor
func loopbackChecks() async {
    print("== ipc loopback ==")
    let sock = "/tmp/fc-selftest-\(getpid()).sock"
    let server = UnixSocketTestServer(path: sock)
    guard server.start() else { checks.check(false, "test server failed to start"); return }
    defer { server.stop() }

    let client = IPCClient()
    let store = VoiceSessionStore()
    store.bind(to: client)
    await client.connect(socketPath: sock)

    guard server.waitForClient(timeout: 3.0) else {
        checks.check(false, "IPCClient never connected"); return
    }
    checks.check(true, "IPCClient connected to socket")

    // python -> app: open a session, then speak.
    server.send(#"{"type":"event","event_type":"SESSION_START","state":"idle"}"#)
    server.send(#"{"type":"event","event_type":"TTS_PLAYBACK_START","state":"speaking"}"#)

    var mapped = false
    for _ in 0..<80 {
        try? await Task.sleep(nanoseconds: 50_000_000)   // yields so MainActor consumer runs
        if store.state == .speaking && store.sessionActive && store.connected { mapped = true; break }
    }
    checks.check(mapped, "store mapped -> speaking + sessionActive + connected")

    // app -> python: control send path writes the exact wire bytes.
    await client.send(.start)
    var got = ""
    for _ in 0..<3 where !got.contains("{\"cmd\":\"start\"}") { got += server.recv() }
    checks.check(got.contains("{\"cmd\":\"start\"}"), "server received start cmd over socket")
}

// MARK: - orb (phase 2) checks

@MainActor
func metalChecks() async {
    print("== orb (phase 2) ==")
    checks.check(MemoryLayout<OrbUniforms>.stride == 48, "OrbUniforms stride == 48 (matches MSL 3x float4)")
    checks.check(orbParams(for: .idle).motion != orbParams(for: .speaking).motion,
                 "orbParams distinct per state (idle vs speaking)")
    if let device = MTLCreateSystemDefaultDevice() {
        do {
            _ = try OrbMetalView.makePipeline(device: device)
            checks.check(true, "orb shader compiles + pipeline builds at runtime (no offline metal compiler)")
        } catch {
            checks.check(false, "orb pipeline build failed: \(error)")
        }
    } else {
        print("  skip: no Metal device available (headless)")
    }
}

// MARK: - swarm (phase 8) checks

@MainActor
func swarmChecks() {
    print("== swarm (phase 8) ==")

    // 1) JSONL decoders against REAL on-disk line shapes.
    let spawnLine = #"{"type":"user","isSidechain":true,"agentId":"a46e7b2c04daf30b7","slug":"litellm-investigator","sessionId":"s","message":{"role":"user","content":"hi"}}"#
    let spawn = SwarmLineDecoder.decode(spawnLine, origin: .agentFile(agentIdFromFilename: "a46e7b2c04daf30b7"))
    checks.check(spawn == .agentSpawn(agentId: "a46e7b2c04daf30b7", slug: "litellm-investigator"),
                 "decode agent-<id>.jsonl spawn line")

    let toolLine = #"{"type":"assistant","agentId":"a46e7b2c04daf30b7","message":{"role":"assistant","content":[{"type":"text","text":"x"},{"type":"tool_use","name":"Bash","input":{}}]}}"#
    let tool = SwarmLineDecoder.decode(toolLine, origin: .agentFile(agentIdFromFilename: "a46e7b2c04daf30b7"))
    checks.check(tool == .toolUse(agentId: "a46e7b2c04daf30b7", tool: "Bash"), "decode appended tool_use line")

    let doneLine = #"{"type":"user","toolUseResult":{"status":"completed","agentId":"a0d942e24aab08a0a","agentType":"researcher","totalTokens":51272,"totalDurationMs":69169,"totalToolUseCount":14,"usage":{"input_tokens":4}}}"#
    let done = SwarmLineDecoder.decode(doneLine, origin: .parentSession)
    checks.check(done == .agentDone(agentId: "a0d942e24aab08a0a", status: .completed, tokens: 51272, durationMs: 69169, toolUseCount: 14),
                 "decode parent toolUseResult completion")

    checks.check(SwarmLineDecoder.agentId(fromFilename: "agent-a46e7b2c04daf30b7.jsonl") == "a46e7b2c04daf30b7",
                 "agentId parsed from filename")
    checks.check(SwarmLineDecoder.decode(#"{"hook":"Stop"}"#, origin: .hook) == .stop, "decode Stop hook ping")

    // 2) Cap-at-16 + done-arc aggregation (deterministic clock).
    let s = SwarmState(now: { 0 })
    for i in 0..<20 { s.applyAgentSpawn(agentId: "id\(i)", slug: nil) }
    checks.check(s.nodes.count == SwarmState.maxVisibleNodes, "nodes capped at 16")
    checks.check(s.totalSpawned == 20, "totalSpawned counts all 20")
    s.applyAgentDone(agentId: "id0", status: .completed, tokens: 100)
    checks.check(s.nodes.first(where: { $0.id == "id0" })?.state == .done, "visible node -> done")
    checks.check(s.nodes.first(where: { $0.id == "id0" })?.tokens == 100, "tokens authoritative on done")
    let beforeArc = s.aggregatedDoneArc
    s.applyAgentDone(agentId: "id18", status: .completed) // id18 never got a visible node (cap)
    checks.check(s.aggregatedDoneArc == beforeArc + 1, "evicted completion -> aggregated done arc")
    s.applyAgentDone(agentId: "id1", status: .failed)
    checks.check(s.nodes.first(where: { $0.id == "id1" })?.state == .failed, "node -> failed (desaturated red)")

    // 3) collapse + reset.
    s.apply(.stop)
    checks.check(s.collapsed, "stop -> collapsed")
    s.reset()
    checks.check(!s.collapsed && s.nodes.isEmpty && s.aggregatedDoneArc == 0 && s.totalSpawned == 0,
                 "reset clears everything")
}

// MARK: - model B: pause/resume + speech text

@MainActor
func modelBChecks() {
    print("== model B pause/resume ==")
    let store = VoiceSessionStore()
    let lv = LocalVoiceController(store: store)

    // Simulate an in-flight read-aloud, then pause. We exercise only the pause path:
    // resume() would call DictationController.start() → AVCaptureDevice.requestAccess,
    // which hard-crashes a bare (un-bundled) binary with no NSMicrophoneUsageDescription
    // — fine in the shipping .app, but not here. So we assert the pause state machine
    // (the regression we care about: pause stops everything) without touching the mic.
    // Regression guard: the default Listen target keeps the Claude Code path (a
    // TranscriptReader) as the first source — unchanged behavior — and adds the desktop
    // source beside it.
    let names = lv.debugSourceTypeNames()
    checks.check(names.first == "TranscriptReader", "default sources keep Claude Code (TranscriptReader) first")
    checks.check(names.contains("ClaudeDesktopSource"), "default sources also include Claude Desktop")

    store.state = .speaking
    store.sessionActive = true
    lv.pause()
    checks.check(lv.isPaused && store.paused, "pause() sets isPaused + store.paused")
    checks.check(store.state == .idle && !store.sessionActive, "pause() forces idle + inactive")
    lv.pause() // idempotent — must not error or flip state
    checks.check(lv.isPaused && store.paused, "pause() is idempotent")

    lv.stop() // mic-safe teardown
}

// MARK: - language profile (Czech routing)

func languageProfileChecks() {
    print("== language profile ==")
    checks.check(LanguageProfile.ttsEngineKind(for: "en") == .kokoro, "en → Kokoro TTS")
    checks.check(LanguageProfile.ttsEngineKind(for: "cs") == .coqui, "cs → Coqui TTS (on-demand neural)")
    checks.check(LanguageProfile.ttsEngineKind(for: "cs-CZ") == .coqui, "cs-CZ → Coqui TTS")
    checks.check(LanguageProfile.ttsEngineKind(for: "fr") == .kokoro, "unknown language → Kokoro (English fallback)")
    checks.check(LanguageProfile.sttLanguage(for: "cs") == "cs", "STT language cs")
    checks.check(LanguageProfile.sttLanguage(for: "en") == "en", "STT language en")
    checks.check(LanguageProfile.sttLanguage(for: "xx") == "en", "STT unknown → en")
    checks.check(LanguageProfile.appleLocale(for: "cs") == "cs-CZ", "Apple locale = cs-CZ for Czech")
    checks.check(LanguageProfile.appleLocale(for: "en") == nil, "Apple locale nil for English")
}

// MARK: - claude desktop settle/de-dup (pure, no AX)

func messageSettlerChecks() {
    print("== claude desktop settler ==")
    var s = MessageSettler(settleInterval: 0.8)
    _ = s.update(current: "", now: 0)                                         // baseline (empty)
    checks.check(s.update(current: "H", now: 0.1) == nil, "streaming: no emit while growing (1)")
    checks.check(s.update(current: "He", now: 0.2) == nil, "streaming: no emit while growing (2)")
    checks.check(s.update(current: "Hello.", now: 0.3) == nil, "streaming: no emit while growing (3)")
    checks.check(s.update(current: "Hello.", now: 0.5) == nil, "stable but not settled (<0.8s)")
    checks.check(s.update(current: "Hello.", now: 1.2) == "Hello.", "settled → emit exactly once")
    checks.check(s.update(current: "Hello.", now: 2.0) == nil, "no re-emit of the same message")
    // A brand-new block (not a prefix-extension) is spoken whole.
    checks.check(s.update(current: "Second message.", now: 2.1) == nil, "new block: streaming")
    checks.check(s.update(current: "Second message.", now: 3.0) == "Second message.", "new block settles → emit")

    // Baseline seeds pre-existing text so on-screen history is never replayed.
    var s2 = MessageSettler(settleInterval: 0.5)
    _ = s2.update(current: "Existing history here.", now: 0)
    checks.check(s2.update(current: "Existing history here.", now: 1.0) == nil, "pre-existing text baselined, not spoken")
}

// MARK: - claude desktop block streaming (pure, no AX)

func messageStreamerChecks() {
    print("== claude desktop streamer ==")
    // defaults: blockSettle 0.25, messageSettle 0.5, firstSettle 0.8
    var st = MessageStreamer()
    _ = st.update(blocks: [], now: 0)                                           // baseline

    // A reply streams in. First block stays held until a later block confirms it's done.
    checks.check(st.update(blocks: ["Hello there."], now: 0.1) == [], "stream: single growing block held (no later block yet)")
    checks.check(st.update(blocks: ["Hello there.", "How are"], now: 0.4) == ["Hello there."],
                 "stream: emit a block once a later block confirms it (one tick stable)")
    checks.check(st.update(blocks: ["Hello there.", "How are you?"], now: 0.7) == [],
                 "stream: trailing block held until the message settles")
    checks.check(st.update(blocks: ["Hello there.", "How are you?"], now: 1.3) == ["How are you?"],
                 "stream: trailing block flushed on settle")
    checks.check(st.update(blocks: ["Hello there.", "How are you?"], now: 2.0) == [],
                 "stream: no re-emit of already-spoken blocks")

    // A user's prompt (single static block that never streams in) is NEVER spoken.
    var st2 = MessageStreamer()
    _ = st2.update(blocks: ["Old conversation block."], now: 0)
    checks.check(st2.update(blocks: ["What is two plus two?"], now: 0.1) == [], "stream: static prompt not spoken (no growth)")
    checks.check(st2.update(blocks: ["What is two plus two?"], now: 1.0) == [], "stream: static single block stays unspoken past firstSettle")

    // A block flushed early (mid-stream pause) then growing emits only the new suffix — no double-speak.
    var st3 = MessageStreamer()
    _ = st3.update(blocks: [], now: 0)
    _ = st3.update(blocks: ["The answer is"], now: 0.1)
    _ = st3.update(blocks: ["The answer is four"], now: 0.4)                    // observed growth → streaming
    checks.check(st3.update(blocks: ["The answer is four"], now: 1.0) == ["The answer is four"],
                 "stream: single streamed block flushed on settle")
    _ = st3.update(blocks: ["The answer is four, definitely."], now: 1.8)       // grew after early flush
    let suffix = st3.update(blocks: ["The answer is four, definitely."], now: 2.5)
    checks.check(suffix.count == 1 && suffix[0].contains("definitely") && !suffix[0].contains("The answer"),
                 "stream: grown block emits only the new suffix (no double-speak)")

    // Multi-block reply is genuine assistant output even without observed growth (count ≥ 2).
    var st4 = MessageStreamer()
    _ = st4.update(blocks: [], now: 0)
    _ = st4.update(blocks: ["First paragraph.", "Second paragraph."], now: 0.1) // first seen
    checks.check(st4.update(blocks: ["First paragraph.", "Second paragraph."], now: 0.4) == ["First paragraph."],
                 "stream: multi-block reply starts without waiting for observed growth")
}

func speechTextChecks() {
    print("== speech text (model B) ==")
    let parts = SpeechText.sentences(
        from: "First here is a long opening clause that should be split, and then more text follows. Second sentence stays whole.")
    checks.check(parts.count >= 3, "long first sentence is split at a clause boundary")
    checks.check(parts.first?.hasSuffix(",") == true, "first clip ends at the comma (faster first audio)")

    let codeOnly = SpeechText.sentences(from: "```\nlet x = 1\n```")
    checks.check(codeOnly.isEmpty, "code-only message yields nothing to speak")

    // Emoji / pictographs / arrows are stripped so TTS never says "party popper"; Czech
    // diacritics are untouched. (Regression guard for the CharacterSet.letters/U+FE0F trap.)
    let glyphy = SpeechText.clean("🎉 Hotovo! Vše funguje ✅ a je to hotové. ⚠️ Pozor → konec.")
    checks.check(!glyphy.contains("🎉") && !glyphy.contains("✅") && !glyphy.contains("⚠")
                 && !glyphy.contains("→") && !glyphy.unicodeScalars.contains("\u{FE0F}"),
                 "clean() strips emoji / pictographs / arrows / variation selectors")
    checks.check(glyphy.contains("Hotovo") && glyphy.contains("hotové") && glyphy.contains("Pozor"),
                 "clean() keeps Czech text + diacritics around stripped glyphs")

    // Compact ("gist") mode — structure-aware extractive (not first+last).
    let short = SpeechText.compact("Only one sentence here.")
    checks.check(short.contains("Only one sentence here."), "compact: short unstructured reply spoken whole")

    let listReply = """
    ## Summary
    Here is the status.
    - Self-trigger is fixed.
    - Czech STT is garbled on the base model.
    - Latency is about one second.
    Want me to tune it further?
    """
    let gist = SpeechText.compact(listReply)
    checks.check(gist.contains("Self-trigger") && gist.contains("garbled"),
                 "compact: keeps whole bullet content (not first-clause fragments)")
    checks.check(!gist.contains("Summary"), "compact: drops heading labels")
    checks.check(gist.contains("?"), "compact: keeps the trailing question as the closer")
    checks.check(gist.count < SpeechText.clean(listReply).count, "compact: shorter than the full reply")

    // A tool-narration opener is demoted, not spoken as the gist.
    let narration = SpeechText.compact(
        "Let me read the file. The bug is in the parser. I fixed it and the tests pass now.")
    checks.check(!narration.hasPrefix("Let me read"), "compact: demotes a tool-narration opener")

    // Code-only message still yields nothing (no 'here is the code' spoken in isolation).
    checks.check(SpeechText.compact("```\nlet x = 1\n```").isEmpty, "compact: code-only → empty")

    // Czech diacritics must survive cleaning + sentence splitting.
    let cz = SpeechText.sentences(from: "Příliš žluťoučký kůň. Úpěl ďábelské ódy.").joined(separator: " ")
    checks.check(cz.contains("ž") && cz.contains("ř") && cz.contains("ů") && cz.contains("ď"),
                 "Czech diacritics preserved through SpeechText")
}

// MARK: - update checker (semver compare, pure)

func updateCheckerChecks() {
    print("== update checker (semver) ==")
    checks.check(SemVer("v0.2.0") == SemVer(0, 2, 0), "parse leading 'v'")
    checks.check(SemVer("0.3.0")! > SemVer("0.2.0")!, "0.3.0 > 0.2.0 (newer is greater)")
    checks.check(SemVer("1.0.0")! > SemVer("0.9.9")!, "major beats minor/patch")
    checks.check(SemVer("0.2.10")! > SemVer("0.2.9")!, "numeric (not lexical) patch compare")
    checks.check(SemVer("v0.2.0-rc1") == SemVer(0, 2, 0), "pre-release suffix ignored")
    checks.check(SemVer("v1.2") == SemVer(1, 2, 0), "missing patch → 0")
    checks.check(SemVer("nonsense") == nil, "garbage tag → nil")
    checks.check(!(SemVer("0.2.0")! > SemVer("0.2.0")!), "equal version is not 'newer'")

    // The updater interpolates filesystem paths into a bash script — quoting must neutralize
    // spaces AND single quotes so a path can never break out of the literal (injection guard).
    checks.check(UpdateController.shSingleQuote("/Users/me/My Project") == "'/Users/me/My Project'",
                 "shSingleQuote wraps a path with spaces")
    checks.check(UpdateController.shSingleQuote("/Users/o'brien/app") == "'/Users/o'\\''brien/app'",
                 "shSingleQuote escapes an embedded single quote (close-escape-reopen)")
}

// MARK: - ready alert phrase (localized, pure)

func readyAlertChecks() {
    print("== ready alert phrase ==")
    checks.check(!SpeechText.readyPhrase(for: "en").isEmpty, "ready phrase (en) is non-empty")
    checks.check(!SpeechText.readyPhrase(for: "cs").isEmpty, "ready phrase (cs) is non-empty")
    checks.check(SpeechText.readyPhrase(for: "cs") != SpeechText.readyPhrase(for: "en"),
                 "ready phrase is localized (cs ≠ en)")
    checks.check(SpeechText.readyPhrase(for: "cs-CZ") == SpeechText.readyPhrase(for: "cs"),
                 "ready phrase resolves cs-CZ as Czech")
    // The cue must be clean, speakable text (no markdown/glyphs that TTS would mangle).
    checks.check(SpeechText.clean(SpeechText.readyPhrase(for: "cs")) == SpeechText.readyPhrase(for: "cs"),
                 "ready phrase is already clean speakable text")
}

// MARK: - watchdog wait-status decode (phase 9)
//
// The watchdog (Helpers/flowcode-watchdog) decodes the Darwin wait(2) status by
// hand because the W* helpers are C function-like macros Swift cannot import.
// Mirror that exact decode here so the contract is covered by the selftest
// (the watchdog itself is a standalone executable with no flowcodeKit dep).
func watchdogChecks() {
    print("== watchdog wait-status decode (phase 9) ==")
    // Replicates the decode in Helpers/flowcode-watchdog/main.swift.
    func decode(_ status: Int32) -> Int32 {
        let termSig = status & 0x7f
        if termSig == 0 { return (status >> 8) & 0xff }   // normal exit
        if termSig != 0x7f { return 128 + termSig }       // killed by signal
        return 0
    }
    // exit code 0 -> status 0x0000
    checks.check(decode(0x0000) == 0, "normal exit 0 -> 0")
    // exit code 42 -> status 0x2a00 (42 << 8)
    checks.check(decode(42 << 8) == 42, "normal exit 42 -> 42")
    // killed by SIGKILL(9) -> low 7 bits = 9 -> 128+9
    checks.check(decode(9) == 137, "SIGKILL -> 137")
    // killed by SIGTERM(15) -> 128+15
    checks.check(decode(15) == 143, "SIGTERM -> 143")
}

// MARK: - entry

wireChecks()
await loopbackChecks()
await metalChecks()
swarmChecks()
modelBChecks()
speechTextChecks()
languageProfileChecks()
messageSettlerChecks()
messageStreamerChecks()
updateCheckerChecks()
readyAlertChecks()
watchdogChecks()
print(checks.failures == 0 ? "\nALL PASS" : "\n\(checks.failures) FAILURE(S)")
exit(checks.failures == 0 ? 0 : 1)
