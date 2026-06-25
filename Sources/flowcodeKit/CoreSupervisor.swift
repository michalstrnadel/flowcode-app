//
//  CoreSupervisor.swift
//  flowcode
//
//  Spawns and supervises the Python voice core as a DIRECT child of the app.
//
//  Why direct (venv python, not `uv run`): the process tree is app -> python, so
//  (1) the macOS microphone TCC grant — owned by flowcode.app, the responsible
//  process — attributes to the core's capture, and (2) the core's parent-death
//  watchdog (getppid -> 1) reliably prevents an orphaned core if the app crashes
//  (no intermediate `uv` layer to keep the python's parent alive).
//
//  The supervisor restarts the core if it exits unexpectedly (simple backoff) and
//  terminates it when the app quits. Spawning is skipped when the python/runner are
//  missing (the app still works against a manually-started core) or when
//  FLOWCODE_MANAGE_CORE=0.
//

import Foundation

@MainActor
public final class CoreSupervisor {

    private var process: Process?
    private var stopping = false
    private var restarts = 0

    private let pythonPath: String
    private let runnerPath: String
    private let workingDir: String
    private let socketPath: String
    private let logURL: URL

    /// - Parameter socketPath: the same UDS path the app's IPC client connects to;
    ///   passed to the core via `VOICEMODE_STATUS_SOCKET` so both agree.
    public init(socketPath: String) {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        // Defaults target this machine's checkout; all overridable via env for
        // portability until the core is embedded in the bundle (Phase 9).
        let forkDefault = "/Users/michalstrnadel/Documents/Macbook M3/Warp/voicecode_claudecode/voicemode"
        self.workingDir = env["FLOWCODE_CORE_CWD"] ?? forkDefault
        self.pythonPath = env["FLOWCODE_CORE_PYTHON"] ?? "\(self.workingDir)/.venv/bin/python"
        self.runnerPath = env["FLOWCODE_RUNNER"] ?? "\(home)/.voicemode/flowcode/flowcode_runner.py"
        self.socketPath = socketPath
        self.logURL = URL(fileURLWithPath: "\(home)/.voicemode/logs/flowcode-core.log")
    }

    /// Spawn the core if management is enabled and the binaries exist.
    public func start() {
        if ProcessInfo.processInfo.environment["FLOWCODE_MANAGE_CORE"] == "0" {
            NSLog("flowcode: core management disabled (FLOWCODE_MANAGE_CORE=0)")
            return
        }
        guard process == nil else { return }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: pythonPath), fm.fileExists(atPath: runnerPath) else {
            NSLog("flowcode: core NOT spawned (missing python or runner): \(pythonPath) | \(runnerPath)")
            return
        }
        launch()
    }

    private func launch() {
        guard !stopping else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = [runnerPath]
        p.currentDirectoryURL = URL(fileURLWithPath: workingDir)

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        // A Finder/`open`-launched .app inherits a minimal PATH; give the core a sane
        // one (homebrew + uv) so its own subprocess tooling resolves.
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["FLOWCODE_PARENT_WATCHDOG"] = "1"      // core exits if we (its parent) die
        env["VOICEMODE_STATUS_SOCKET"] = socketPath
        p.environment = env

        if let handle = logHandle() {
            p.standardOutput = handle
            p.standardError = handle
        }

        // terminationHandler runs off the main actor; capture only the Sendable status.
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in self?.handleExit(status: status) }
        }

        do {
            try p.run()
            process = p
            NSLog("flowcode: voice core spawned (pid \(p.processIdentifier))")
        } catch {
            NSLog("flowcode: core spawn failed: \(error)")
            process = nil
        }
    }

    /// Append-mode handle to the core log, creating the file/dir as needed.
    private func logHandle() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: logURL)
        h?.seekToEndOfFile()
        return h
    }

    private func handleExit(status: Int32) {
        process = nil
        guard !stopping else { return }
        restarts += 1
        let delay = min(10.0, Double(restarts))   // 1s, 2s, ... capped at 10s
        NSLog("flowcode: voice core exited (status \(status)); restarting in \(Int(delay))s")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.launch()
        }
    }

    /// Stop supervising and terminate the core (SIGTERM). The core also self-exits via
    /// its parent-death watchdog, so this is belt-and-suspenders.
    public func stop() {
        stopping = true
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }
}
