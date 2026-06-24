//
//  flowcode-watchdog — tiny sidecar that guarantees the Python voice core dies
//  with the app.
//
//  Foundation.Process does NOT reap a grandchild when the app crashes: if
//  flowcode.app is force-killed (SIGKILL), the python core it spawned is
//  reparented to launchd (PID 1) and keeps holding the mic + audio devices.
//  This helper closes that gap, mirroring CodexBar's `CodexBarClaudeWatchdog`:
//
//    1. posix_spawnp() the python core in its OWN process group (setpgid), so we
//       can signal the whole group (interpreter + any worker it forks).
//    2. Poll getppid(): when OUR parent (flowcode.app) dies we are reparented to
//       launchd and getppid() == 1. That is the death signal.
//    3. On parent death (or child exit): SIGTERM the group, grace period, then
//       SIGKILL anything still alive. Exit with the child's status.
//
//  Self-contained: builds standalone with
//      swiftc -O Helpers/flowcode-watchdog/main.swift -o flowcode-watchdog
//  No flowcodeKit dependency. Lives in flowcode.app/Contents/Helpers/.
//
//  Invocation (by main.swift's spawner, in a later phase):
//      flowcode-watchdog <python-exe> [args...]
//  e.g. flowcode-watchdog .../Contents/Resources/python/bin/python -m voice_mode ...
//

import Darwin
import Foundation

// MARK: - args

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    FileHandle.standardError.write(Data("flowcode-watchdog: usage: flowcode-watchdog <exe> [args...]\n".utf8))
    exit(2)
}
let childPath = argv[1]
let childArgs = Array(argv.dropFirst(1))   // argv[0] of the child = the exe itself

// Tunables (env-overridable so the spawner can adjust without a rebuild).
let pollIntervalUs: useconds_t = {
    if let s = ProcessInfo.processInfo.environment["FLOWCODE_WATCHDOG_POLL_MS"], let ms = Int(s), ms > 0 {
        return useconds_t(ms * 1000)
    }
    return 250_000   // 250ms
}()
let graceSeconds: Double = {
    if let s = ProcessInfo.processInfo.environment["FLOWCODE_WATCHDOG_GRACE_S"], let g = Double(s), g >= 0 {
        return g
    }
    return 3.0
}()

// MARK: - spawn the child in its own process group

func spawnChild() -> pid_t {
    // posix_spawn_file_actions_t / posix_spawnattr_t import into Swift as opaque
    // optional pointers; init to nil and let the C *_init populate them.
    var fileActions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }

    // POSIX_SPAWN_SETPGROUP with pgroup 0 => child becomes leader of a NEW group
    // whose id == the child's pid. We signal that whole group on teardown.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)

    // Build the C argv (NULL-terminated) and inherit the environment.
    var cArgs: [UnsafeMutablePointer<CChar>?] = childArgs.map { strdup($0) }
    cArgs.append(nil)
    defer { for p in cArgs where p != nil { free(p) } }

    var pid: pid_t = -1
    let rc = posix_spawnp(&pid, childPath, &fileActions, &attr, cArgs, environ)
    guard rc == 0 else {
        FileHandle.standardError.write(Data("flowcode-watchdog: posix_spawnp failed: \(String(cString: strerror(rc)))\n".utf8))
        exit(127)
    }
    return pid
}

// MARK: - teardown

/// SIGTERM the child's process group, wait up to `graceSeconds`, then SIGKILL.
/// Returns once the child is reaped (or we gave up).
func terminateGroup(_ pid: pid_t) {
    // Negative pid => signal the whole process group led by `pid`.
    kill(-pid, SIGTERM)

    let deadline = Date().addingTimeInterval(graceSeconds)
    while Date() < deadline {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid || (r == -1 && errno == ECHILD) { return }   // reaped / gone
        usleep(50_000)   // 50ms
    }
    // Grace expired — force-kill the group, then a final blocking reap.
    kill(-pid, SIGKILL)
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
}

// MARK: - main loop

let child = spawnChild()

// Watch both directions:
//   * child exits on its own        -> waitpid succeeds, mirror its status.
//   * parent (flowcode.app) dies    -> getppid() becomes 1, tear the child down.
while true {
    var status: Int32 = 0
    let r = waitpid(child, &status, WNOHANG)
    if r == child {
        // Child exited; propagate a faithful exit code. The W* helpers are C
        // function-like macros that Swift cannot import, so decode the Darwin
        // wait status by hand: low 7 bits = terminating signal (0 => normal
        // exit), next byte = exit code.
        let termSig = status & 0x7f
        if termSig == 0 {
            exit((status >> 8) & 0xff)          // WIFEXITED: normal exit
        } else if termSig != 0x7f {
            exit(128 + termSig)                 // WIFSIGNALED: killed by signal
        }
        exit(0)                                 // stopped/continued: shouldn't happen here
    } else if r == -1 && errno == ECHILD {
        exit(0)   // already reaped somehow
    }

    if getppid() == 1 {
        // Orphaned: our app died. Kill the core and follow it out.
        terminateGroup(child)
        exit(0)
    }

    usleep(pollIntervalUs)
}
