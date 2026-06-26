//
//  UpdateController.swift
//  flowcode
//
//  A minimal, dependency-free "Check for Updates" for flowcode.
//
//  flowcode ships **from source** (self-signed `flowcode-dev`, not notarized), so the Sparkle
//  keys in Info.plist are inert: there is no signed appcast and the GitHub releases carry no
//  downloadable binaries. Rather than fake a download, this checks the latest published GitHub
//  release and, when the local checkout can be found, offers a one-click rebuild-from-source +
//  relaunch — the same idempotent `scripts/setup.sh` path the project documents. When the
//  checkout can't be located it falls back to opening the Releases page. (A real Sparkle
//  auto-update is a later milestone: it needs a paid Apple Developer ID, notarization, and an
//  EdDSA-signed appcast.)
//

import AppKit
import Foundation

@MainActor
public final class UpdateController {

    private let owner: String
    private let repo: String
    private let currentVersion: SemVer
    private var isChecking = false

    public init() {
        let (o, r) = Self.resolveOwnerRepo()
        self.owner = o
        self.repo = r
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.currentVersion = SemVer(v ?? "0.0.0") ?? SemVer(0, 0, 0)
    }

    /// Check GitHub for a newer release and present the result. Idempotent while in flight
    /// (a second menu click is ignored until the first check resolves).
    public func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task { [weak self] in
            await self?.run()
            self?.isChecking = false
        }
    }

    private func run() async {
        do {
            let release = try await fetchLatestRelease()
            if release.version > currentVersion {
                presentUpdateAvailable(release)
            } else {
                presentUpToDate()
            }
        } catch UpdateError.noReleases {
            presentNoReleases()
        } catch {
            presentError()
        }
    }

    // MARK: - Networking

    private enum UpdateError: Error { case noReleases }

    private struct Release { let version: SemVer; let tag: String; let htmlURL: URL? }

    private func fetchLatestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("flowcode-updater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // GitHub returns 404 (not an empty 200) when a repo has no published, non-draft,
        // non-prerelease release — that's "nothing to compare against", not a network failure.
        if http.statusCode == 404 { throw UpdateError.noReleases }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tag = obj?["tag_name"] as? String, let version = SemVer(tag) else {
            throw URLError(.cannotParseResponse)
        }
        let html = (obj?["html_url"] as? String).flatMap { URL(string: $0) }
        return Release(version: version, tag: tag, htmlURL: html)
    }

    // MARK: - Presentation

    private func presentUpToDate() {
        let a = NSAlert()
        a.messageText = "flowcode is up to date"
        a.informativeText = "You have version \(currentVersion.description)."
        a.addButton(withTitle: "OK")
        runModal(a)
    }

    private func presentError() {
        let a = NSAlert()
        a.messageText = "Couldn't check for updates"
        a.informativeText =
            "flowcode couldn't reach GitHub. Check your connection, or open the Releases page manually."
        a.addButton(withTitle: "Open Releases Page")
        a.addButton(withTitle: "Cancel")
        if runModal(a) == .alertFirstButtonReturn { openReleasesPage() }
    }

    private func presentNoReleases() {
        let a = NSAlert()
        a.messageText = "No published releases yet"
        a.informativeText =
            "There's no published flowcode release to compare against yet (you have \(currentVersion.description))."
        a.addButton(withTitle: "Open Releases Page")
        a.addButton(withTitle: "Cancel")
        if runModal(a) == .alertFirstButtonReturn { openReleasesPage() }
    }

    private func presentUpdateAvailable(_ release: Release) {
        let repoPath = Self.locateRepo()
        let a = NSAlert()
        a.messageText = "flowcode \(release.version.description) is available"

        if let repoPath {
            a.informativeText = """
            You have \(currentVersion.description). flowcode installs from source, so updating \
            pulls the latest code, rebuilds, and relaunches the app (it opens Terminal so you can \
            watch the build).

            Source: \(repoPath)
            """
            a.addButton(withTitle: "Update & Relaunch")
            a.addButton(withTitle: "Release Notes")
            a.addButton(withTitle: "Cancel")
            switch runModal(a) {
            case .alertFirstButtonReturn:  runUpdate(repoPath: repoPath)
            case .alertSecondButtonReturn: openReleaseNotes(release)
            default: break
            }
        } else {
            a.informativeText = """
            You have \(currentVersion.description). flowcode installs from source — pull the latest \
            code and re-run scripts/setup.sh in your checkout to update.
            """
            a.addButton(withTitle: "Release Notes")
            a.addButton(withTitle: "Open Releases Page")
            a.addButton(withTitle: "Cancel")
            switch runModal(a) {
            case .alertFirstButtonReturn:  openReleaseNotes(release)
            case .alertSecondButtonReturn: openReleasesPage()
            default: break
            }
        }
    }

    /// flowcode is an `.accessory` (menu-bar) app, so bring it forward before showing a modal
    /// alert or the window can appear behind everything / not at all.
    @discardableResult
    private func runModal(_ a: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal()
    }

    private func openReleaseNotes(_ release: Release) {
        if let url = release.htmlURL { NSWorkspace.shared.open(url) } else { openReleasesPage() }
    }

    private func openReleasesPage() {
        if let url = URL(string: "https://github.com/\(owner)/\(repo)/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Rebuild from source

    private func runUpdate(repoPath: String) {
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = Self.updateScript(repoPath: repoPath, appPath: appPath, pid: pid)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flowcode-update.command")
        do {
            try script.write(to: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        } catch {
            presentError()
            return
        }
        // Run the script in Terminal so the user sees the build progress and any keychain
        // prompt; the script quits + relaunches flowcode itself once the build finishes.
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([tmp], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    /// The detached updater: pull, rebuild + re-sign via the project's own setup.sh, then stop
    /// and relaunch the app. The build runs FIRST (the app stays up so the menu bar isn't empty
    /// during the multi-minute build), and any failure before the swap leaves the running app
    /// untouched. Only once the build succeeds is the process stopped (waiting for it to exit),
    /// the bundle replaced (not merged over a live one), and a FRESH instance launched.
    private static func updateScript(repoPath: String, appPath: String, pid: Int32) -> String {
        let repo = shSingleQuote(repoPath)
        let app = shSingleQuote(appPath)
        return """
        #!/bin/bash
        # flowcode in-app updater. Failures BEFORE the swap leave your running flowcode intact.
        REPO=\(repo)
        APP=\(app)
        PID=\(pid)
        NEW="$REPO/dist/flowcode.app"

        echo '== flowcode update =='
        cd "$REPO" || { echo "Source checkout not found: $REPO"; exit 1; }

        echo '-> checking git'
        git fetch --quiet || { echo 'git fetch failed — are you online?'; exit 1; }
        if [ -n "$(git status --porcelain)" ]; then
          echo 'Your checkout has local changes. Commit or stash them, then run Update again. Aborting.'
          exit 1
        fi
        if ! git pull --ff-only; then
          echo 'Cannot fast-forward (diverged / no upstream). Update your checkout manually. Aborting.'
          exit 1
        fi

        echo '-> rebuild + sign (this can take a few minutes)'
        # Re-sign with the identity the running app ALREADY uses, so the macOS TCC grants
        # (Microphone / Accessibility) survive the update. When none can be recovered, setup.sh
        # falls back to its own detection (Developer ID, else ad-hoc).
        if [ -z "${SIGN_IDENTITY:-}" ]; then
          CUR_ID="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
          [ -n "$CUR_ID" ] && export SIGN_IDENTITY="$CUR_ID"
        fi
        if ! ./scripts/setup.sh --skip-services --skip-mcp-cleanup --skip-permissions; then
          echo 'Build/sign failed — your current flowcode is untouched and still running. Aborting.'
          exit 1
        fi

        echo '-> restarting flowcode'
        osascript -e 'tell application "flowcode" to quit' >/dev/null 2>&1 || true
        if [ "$PID" -gt 0 ] 2>/dev/null; then
          for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
          kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
        else
          pkill -x flowcode 2>/dev/null || true
          sleep 1
        fi

        if [ "$APP" != "$NEW" ]; then
          # Replace (don't ditto-merge over) the old bundle now that the process has exited.
          rm -rf "$APP.old" 2>/dev/null || true
          if mv "$APP" "$APP.old" 2>/dev/null; then
            if /usr/bin/ditto "$NEW" "$APP"; then
              rm -rf "$APP.old" 2>/dev/null || true
            else
              echo 'Install failed; restoring the previous version.'
              rm -rf "$APP" 2>/dev/null || true
              mv "$APP.old" "$APP" 2>/dev/null || true
            fi
          else
            echo "Could not replace $APP (permission?). Run manually: ditto \\"$NEW\\" \\"$APP\\""
          fi
        fi

        open -n "$APP"
        echo 'Update complete. You can close this window.'
        """
    }

    /// Wrap a path as a safe single-quoted bash literal (escaping any embedded single quote),
    /// so a checkout / install path with spaces or an apostrophe can't break — or inject into —
    /// the generated script. (Exposed for the selftest's injection-safety assertion.)
    public nonisolated static func shSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Discovery helpers

    /// Owner/repo parsed from the Info.plist `SUFeedURL` (which cascades from version.env's
    /// `APPCAST_URL`), falling back to the known coordinates. Only READS the plist — never edits
    /// it (editing Info.plist would invalidate the signature and drop the TCC grants).
    private static func resolveOwnerRepo() -> (String, String) {
        let fallback = ("michalstrnadel", "flowcode-app")
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let comps = URLComponents(string: feed),
              comps.host?.contains("github.com") == true else { return fallback }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return fallback }
        return (parts[0], parts[1])
    }

    /// Locate the source checkout to rebuild from: the path recorded at build time
    /// (`Resources/source-repo.txt`), else derived when running from `<repo>/dist/flowcode.app`,
    /// else nil (→ caller falls back to the Releases page).
    private static func locateRepo() -> String? {
        if let url = Bundle.main.url(forResource: "source-repo", withExtension: "txt"),
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isGitRepo(path) { return path }
        }
        // Running from "<repo>/dist/flowcode.app" → the repo is two levels up.
        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath)
        if bundle.deletingLastPathComponent().lastPathComponent == "dist" {
            let repo = bundle.deletingLastPathComponent().deletingLastPathComponent().path
            if isGitRepo(repo) { return repo }
        }
        return nil
    }

    private static func isGitRepo(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let git = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: git)
    }
}

// MARK: - SemVer (pure, testable)

/// Tiny semantic-version value for comparing release tags. Tolerant: accepts an optional
/// leading "v", ignores any pre-release / build-metadata suffix (`-rc1`, `+build`), and treats
/// missing components as 0 (so `v1.2` == `1.2.0`). Compared numerically, not lexically.
public struct SemVer: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let comps = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard let firstComp = comps.first, let mj = firstComp else { return nil }
        self.major = mj
        self.minor = comps.count > 1 ? (comps[1] ?? 0) : 0
        self.patch = comps.count > 2 ? (comps[2] ?? 0) : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (l: SemVer, r: SemVer) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}
