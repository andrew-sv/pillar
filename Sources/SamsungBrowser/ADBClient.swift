import Foundation
import SwiftUI

struct Device: Identifiable, Hashable {
    let id: String        // serial
    let model: String
    let state: String     // "device", "unauthorized", etc.

    var displayName: String {
        if model.isEmpty { return id }
        return "\(model) (\(id))"
    }
}

struct DeviceFile: Identifiable, Hashable {
    let id: String        // full path acts as stable id within a directory
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let permissions: String
    let modifiedString: String
    let linkTarget: String?

    var displaySize: String {
        if isDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct Transfer: Identifiable, Equatable {
    enum Direction { case pull, push }
    let id = UUID()
    let label: String
    let direction: Direction
}

enum ADBError: LocalizedError {
    case notInstalled
    case noDeviceSelected
    case command(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "adb not found. Install it with: brew install --cask android-platform-tools"
        case .noDeviceSelected:
            return "No device selected."
        case .command(let msg):
            return msg
        }
    }
}

@MainActor
final class ADBClient: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selectedDeviceID: String?
    @Published var adbPath: String?
    @Published var setupError: String?
    @Published var transfers: [Transfer] = []

    init() {
        self.adbPath = Self.locateADB()
        if adbPath == nil {
            setupError = ADBError.notInstalled.errorDescription
        }
    }

    // MARK: - adb binary discovery

    private static func locateADB() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Android/sdk/platform-tools/adb"),
            "/Applications/Android Studio.app/Contents/Library/Android/sdk/platform-tools/adb"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fallback: ask /usr/bin/env
        if let p = try? runSync("/usr/bin/env", ["which", "adb"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !p.isEmpty,
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    // MARK: - Process plumbing

    private struct ProcResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private static func runSync(_ exe: String, _ args: [String]) throws -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcResult(stdout: out, stderr: err, exitCode: p.terminationStatus)
    }

    private func run(_ args: [String]) async throws -> ProcResult {
        guard let adb = adbPath else { throw ADBError.notInstalled }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: ProcResult(stdout: out, stderr: err, exitCode: proc.terminationStatus))
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private func adbArgs(_ extra: [String], requireDevice: Bool = true) throws -> [String] {
        if requireDevice {
            guard let serial = selectedDeviceID else { throw ADBError.noDeviceSelected }
            return ["-s", serial] + extra
        }
        return extra
    }

    private func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Devices

    func refreshDevices() async {
        do {
            let res = try await run(["devices", "-l"])
            // Format:
            // List of devices attached
            // R5CT12345    device usb:... product:... model:SM_G998B device:o1q transport_id:1
            var found: [Device] = []
            for line in res.stdout.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("List of devices") { continue }
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 2 else { continue }
                let serial = parts[0]
                let state = parts[1]
                var model = ""
                for p in parts.dropFirst(2) where p.hasPrefix("model:") {
                    model = String(p.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
                }
                found.append(Device(id: serial, model: model, state: state))
            }
            self.devices = found
            if let sel = selectedDeviceID, !found.contains(where: { $0.id == sel }) {
                selectedDeviceID = nil
            }
            if selectedDeviceID == nil, let first = found.first(where: { $0.state == "device" }) {
                selectedDeviceID = first.id
            }
        } catch {
            setupError = error.localizedDescription
        }
    }

    // MARK: - Filesystem ops

    func list(_ path: String) async throws -> [DeviceFile] {
        var current = path
        for _ in 0..<8 {
            let entries = try await listOnce(current)
            // ls on an old toolbox may print just the symlink record instead of following it.
            // Detect and follow manually.
            if entries.count == 1,
               let only = entries.first,
               only.isSymlink,
               only.name == (current as NSString).lastPathComponent,
               let target = only.linkTarget {
                current = target.hasPrefix("/")
                    ? target
                    : ((current as NSString).deletingLastPathComponent as NSString)
                        .appendingPathComponent(target)
                continue
            }
            return entries
        }
        return []
    }

    private func listOnce(_ path: String) async throws -> [DeviceFile] {
        // Trailing slash forces ls to dereference a symlink and list the target's contents.
        let dirPath = path.hasSuffix("/") ? path : path + "/"
        let cmd = "ls -la \(shellQuote(dirPath))"
        let args = try adbArgs(["shell", cmd])
        let res = try await run(args)
        if res.exitCode != 0 {
            throw ADBError.command(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parseListing(res.stdout, parentPath: path)
    }

    func pull(_ remotePath: String, to localURL: URL) async throws {
        let label = (remotePath as NSString).lastPathComponent
        let transfer = Transfer(label: label, direction: .pull)
        transfers.append(transfer)
        defer { transfers.removeAll { $0.id == transfer.id } }

        let args = try adbArgs(["pull", remotePath, localURL.path])
        let res = try await run(args)
        if res.exitCode != 0 {
            throw ADBError.command((res.stderr.isEmpty ? res.stdout : res.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func push(_ localURL: URL, toRemoteDir dir: String) async throws {
        let label = localURL.lastPathComponent
        let transfer = Transfer(label: label, direction: .push)
        transfers.append(transfer)
        defer { transfers.removeAll { $0.id == transfer.id } }

        let remote = dir.hasSuffix("/") ? dir : dir + "/"
        let args = try adbArgs(["push", localURL.path, remote])
        let res = try await run(args)
        if res.exitCode != 0 {
            throw ADBError.command((res.stderr.isEmpty ? res.stdout : res.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func delete(_ path: String) async throws {
        let cmd = "rm -rf \(shellQuote(path))"
        let args = try adbArgs(["shell", cmd])
        let res = try await run(args)
        if res.exitCode != 0 {
            throw ADBError.command(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        let cmd = "mv \(shellQuote(oldPath)) \(shellQuote(newPath))"
        let args = try adbArgs(["shell", cmd])
        let res = try await run(args)
        if res.exitCode != 0 {
            throw ADBError.command(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func mkdir(_ path: String) async throws {
        let cmd = "mkdir -p \(shellQuote(path))"
        let args = try adbArgs(["shell", cmd])
        let res = try await run(args)
        if res.exitCode != 0 {
            throw ADBError.command(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Pulls a remote file or directory into a fresh temp location and returns the local URL.
    func pullToTemp(_ remotePath: String) async throws -> URL {
        let name = (remotePath as NSString).lastPathComponent
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SamsungBrowser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try await pull(remotePath, to: dest)
        return dest
    }

    // MARK: - Listing parser

    private func parseListing(_ output: String, parentPath: String) -> [DeviceFile] {
        var result: [DeviceFile] = []
        // NB: in Swift, "\r\n" is one grapheme cluster, so splitting on Character("\n")
        // misses every CRLF terminator. Use CharacterSet.newlines via components(separatedBy:).
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("total ") { continue }
            guard let row = parseRow(line, parentPath: parentPath) else { continue }
            result.append(row)
        }
        result.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return result
    }

    /// Parses one `ls -l` row. Robust to both modern toybox (`perms links owner group size date time name`)
    /// and older toolbox where dirs/symlinks omit the size column. The date pattern (YYYY-MM-DD) is the
    /// anchor — once we know its position we can read size (token before, if numeric) and name (everything
    /// after the time token).
    private func parseRow(_ line: String, parentPath: String) -> DeviceFile? {
        // Tokenize, recording the end-position of each token so we can slice the name reliably.
        var tokens: [(value: String, end: String.Index)] = []
        var idx = line.startIndex
        while idx < line.endIndex {
            while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
                idx = line.index(after: idx)
            }
            let start = idx
            while idx < line.endIndex, line[idx] != " ", line[idx] != "\t" {
                idx = line.index(after: idx)
            }
            if start < idx {
                tokens.append((String(line[start..<idx]), idx))
            }
        }
        guard tokens.count >= 4 else { return nil }
        let perms = tokens[0].value
        guard let first = perms.first, "-dlcsbpL".contains(first) else { return nil }

        guard let dateIdx = tokens.firstIndex(where: { Self.isDate($0.value) }),
              dateIdx + 1 < tokens.count else { return nil }

        var size: Int64 = 0
        if dateIdx >= 1, let n = Int64(tokens[dateIdx - 1].value) {
            size = n
        }
        let timeTok = tokens[dateIdx + 1]
        var name = String(line[timeTok.end...]).trimmingCharacters(in: .whitespaces)
        var linkTarget: String? = nil
        if let arrow = name.range(of: " -> ") {
            linkTarget = String(name[arrow.upperBound...])
            name = String(name[..<arrow.lowerBound])
        }
        if name.isEmpty || name == "." || name == ".." { return nil }

        let isDir = perms.hasPrefix("d")
        let isLink = perms.hasPrefix("l")
        let path = parentPath.hasSuffix("/")
            ? "\(parentPath)\(name)"
            : "\(parentPath)/\(name)"
        return DeviceFile(
            id: path,
            name: name,
            path: path,
            isDirectory: isDir,
            isSymlink: isLink,
            size: size,
            permissions: perms,
            modifiedString: "\(tokens[dateIdx].value) \(timeTok.value)",
            linkTarget: linkTarget
        )
    }

    private static func isDate(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        let c = Array(s)
        return c[0].isNumber && c[1].isNumber && c[2].isNumber && c[3].isNumber
            && c[4] == "-" && c[5].isNumber && c[6].isNumber
            && c[7] == "-" && c[8].isNumber && c[9].isNumber
    }
}
