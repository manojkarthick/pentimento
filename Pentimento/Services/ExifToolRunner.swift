import Foundation
import Darwin

struct ExifToolOutput {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func set(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }
}

struct ExifToolRunner {
    let executable: URL
    let prefix: [String]

    static func bundledOrLocal() throws -> ExifToolRunner {
        let file = Bundle.main.resourceURL?.appendingPathComponent("ExifTool/exiftool")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"), let file,
           FileManager.default.fileExists(atPath: file.path) {
            return ExifToolRunner(executable: URL(fileURLWithPath: "/usr/bin/perl"), prefix: [file.path])
        }
        for path in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"] where FileManager.default.isExecutableFile(atPath: path) {
            return ExifToolRunner(executable: URL(fileURLWithPath: path), prefix: [])
        }
        throw InspectorError.message("ExifTool is unavailable. The bundled copy and local installations could not be found.")
    }

    static func readArguments(_ url: URL) -> [String] {
        ["-json", "-long", "-G0:1", "-a", "-api", "LargeFileSupport=1", "--", url.path]
    }
    static func selectedArguments(_ keys: [String], url: URL) -> [String] {
        ["-overwrite_original", "-P"] + keys.map { "-\($0)=" } + ["--", url.path]
    }
    static func broadArguments(_ url: URL, preserveLivePhoto: Bool = false) -> [String] {
        var arguments = ["-overwrite_original", "-P", "-all=", "--ICC_Profile:all", "-tagsFromFile", "@", "-ColorSpaceTags", "-Orientation", "-PNG:SRGBRendering"]
        if preserveLivePhoto {
            arguments += ["-MakerNotes", "-Make", "-Model", "-Keys:ContentIdentifier", "-XMP:ContentIdentifier"]
        }
        return arguments + ["--", url.path]
    }

    private static func readLimited(_ handle: FileHandle, controller: ProcessController) -> Data {
        var data = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count > 10_000_000 {
                controller.cancel()
                data.append(chunk.prefix(max(0, 10_000_001 - data.count)))
                break
            }
            data.append(chunk)
        }
        return data
    }

    func run(_ arguments: [String], timeout: TimeInterval = 60) async throws -> ExifToolOutput {
        let controller = ProcessController()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let process = Process()
                        process.executableURL = executable
                        process.arguments = prefix + arguments
                        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]) { _, new in new }
                        let out = Pipe(), err = Pipe()
                        process.standardOutput = out
                        process.standardError = err
                        controller.set(process)
                        try process.run()
                        if controller.isCancelled { process.terminate() }
                        let group = DispatchGroup()
                        var outData = Data(), errData = Data()
                        group.enter()
                        DispatchQueue.global().async { outData = Self.readLimited(out.fileHandleForReading, controller: controller); group.leave() }
                        group.enter()
                        DispatchQueue.global().async { errData = Self.readLimited(err.fileHandleForReading, controller: controller); group.leave() }
                        let deadline = Date().addingTimeInterval(timeout)
                        var timedOut = false
                        while process.isRunning {
                            if Date() > deadline {
                                timedOut = true
                                process.terminate()
                                Thread.sleep(forTimeInterval: 0.25)
                                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                                break
                            }
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                        process.waitUntilExit()
                        group.wait()
                        if timedOut { throw InspectorError.message("ExifTool timed out after \(Int(timeout)) seconds.") }
                        if outData.count > 10_000_000 || errData.count > 10_000_000 {
                            throw InspectorError.message("ExifTool output exceeded the 10 MB limit.")
                        }
                        if controller.isCancelled { throw CancellationError() }
                        continuation.resume(returning: ExifToolOutput(stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self), exitCode: process.terminationStatus))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { controller.cancel() }
    }
}
