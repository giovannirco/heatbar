import AppKit
import Darwin
import ServiceManagement

struct StressError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func logicalCPUCount() throws -> Int {
    var n: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.ncpu", &n, &size, nil, 0) != 0 || n < 1 {
        throw StressError(message: "Could not read hw.ncpu")
    }
    return Int(n)
}

func executablePath(pid: Int32) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard n > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(n)), as: UTF8.self)
}

func supportDirectory() throws -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("HeatBar", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    return dir
}

final class StressController {
    private let lock = NSLock()
    private var cpus: [Process] = []
    private var gpu: Process?
    private var activity: NSObjectProtocol?
    private(set) var lastError: String?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gpu != nil
    }

    func reapStale() {
        guard let url = pidFile() else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let pid = Int32(line), pid > 1 else { continue }
            guard let path = executablePath(pid: pid) else { continue }
            let name = (path as NSString).lastPathComponent
            if name == "yes" || name == "gpu-heat" {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func start() throws {
        if isRunning { return }
        let n = try logicalCPUCount()
        let gpuURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gpu-heat")
        guard FileManager.default.isExecutableFile(atPath: gpuURL.path) else {
            throw StressError(message: "gpu-heat is missing from the app")
        }
        var spawned: [Process] = []
        var gpuProcess: Process?
        do {
            for _ in 0..<n {
                spawned.append(try launch(URL(fileURLWithPath: "/usr/bin/yes")))
            }
            let started = try launch(gpuURL)
            gpuProcess = started
            Thread.sleep(forTimeInterval: 0.4)
            if !started.isRunning {
                throw StressError(message: "GPU stress exited")
            }
            lock.lock()
            cpus = spawned
            gpu = started
            lastError = nil
            lock.unlock()
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "CPU and GPU stress"
                )
            }
            try writePids()
        } catch {
            for process in spawned { terminate(process) }
            if let gpuProcess { terminate(gpuProcess) }
            throw error
        }
    }

    func stop() {
        lock.lock()
        let procs = cpus + (gpu.map { [$0] } ?? [])
        cpus = []
        gpu = nil
        lock.unlock()
        for process in procs { terminate(process) }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if let url = pidFile() { try? FileManager.default.removeItem(at: url) }
    }

    func setError(_ message: String) {
        lock.lock()
        lastError = message
        lock.unlock()
    }

    func clearError() {
        lock.lock()
        lastError = nil
        lock.unlock()
    }

    private func launch(_ url: URL) throws -> Process {
        guard
            let sink = FileHandle(forWritingAtPath: "/dev/null"),
            let source = FileHandle(forReadingAtPath: "/dev/null")
        else {
            throw StressError(message: "Could not open /dev/null")
        }
        let process = Process()
        process.executableURL = url
        process.qualityOfService = .userInitiated
        process.standardInput = source
        process.standardOutput = sink
        process.standardError = sink
        process.terminationHandler = { _ in }
        try process.run()
        return process
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func pidFile() -> URL? {
        guard let dir = try? supportDirectory() else { return nil }
        return dir.appendingPathComponent("pids")
    }

    private func writePids() throws {
        guard let url = pidFile() else { throw StressError(message: "No pid file path") }
        lock.lock()
        let ids = cpus.map(\.processIdentifier) + (gpu.map { [$0.processIdentifier] } ?? [])
        lock.unlock()
        let body = ids.map(String.init).joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class ControlServer {
    private let fd: Int32
    private let queue = DispatchQueue(label: "io.github.giovannirco.heatbar.socket")

    init(path: String) throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw StressError(message: "socket failed") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count + 1 < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw StressError(message: "Socket path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bound != 0 || listen(fd, 4) != 0 {
            close(fd)
            throw StressError(message: "Could not bind \(path)")
        }
        chmod(path, 0o600)
        self.fd = fd
    }

    func serve(handler: @escaping (String) -> String) {
        queue.async { [fd] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                var buffer = [UInt8](repeating: 0, count: 64)
                let n = read(client, &buffer, buffer.count)
                let command = n > 0 ? String(decoding: buffer.prefix(n), as: UTF8.self) : ""
                let reply = handler(command.trimmingCharacters(in: .whitespacesAndNewlines))
                _ = reply.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let stress = StressController()
    private let work = DispatchQueue(label: "io.github.giovannirco.heatbar.work")
    private var server: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        stress.reapStale()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        do {
            let dir = try supportDirectory()
            let socketPath = dir.appendingPathComponent("control.sock").path
            let server = try ControlServer(path: socketPath)
            server.serve { [weak self] command in
                guard let self else { return "err gone\n" }
                return self.work.sync { self.handle(command) }
            }
            self.server = server
        } catch {
            stress.setError(error.localizedDescription)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        work.sync { stress.stop() }
        return .terminateNow
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let running = stress.isRunning
        let toggle = NSMenuItem(
            title: running ? "Stop stress" : "Start stress",
            action: #selector(toggleStress),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        let state = NSMenuItem(
            title: running ? "CPU and GPU are under load" : "Idle",
            action: nil,
            keyEquivalent: ""
        )
        state.isEnabled = false
        menu.addItem(state)
        if let message = stress.lastError {
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit HeatBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleStress() {
        work.sync {
            do {
                if stress.isRunning {
                    stress.stop()
                } else {
                    try stress.start()
                }
                stress.clearError()
            } catch {
                stress.setError(error.localizedDescription)
            }
        }
        updateIcon()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            stress.clearError()
        } catch {
            stress.setError(error.localizedDescription)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handle(_ command: String) -> String {
        switch command {
        case "start":
            do {
                try stress.start()
                stress.clearError()
                DispatchQueue.main.async { self.updateIcon() }
                return "ok running\n"
            } catch {
                stress.setError(error.localizedDescription)
                return "err \(error.localizedDescription)\n"
            }
        case "stop":
            stress.stop()
            stress.clearError()
            DispatchQueue.main.async { self.updateIcon() }
            return "ok stopped\n"
        case "status":
            return stress.isRunning ? "ok running\n" : "ok stopped\n"
        default:
            return "err unknown\n"
        }
    }

    private func updateIcon() {
        let running = stress.isRunning
        let image = NSImage(
            systemSymbolName: running ? "flame.fill" : "flame",
            accessibilityDescription: running ? "Stress on" : "Stress off"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = running ? "HeatBar: stressing" : "HeatBar: idle"
    }
}

signal(SIGPIPE, SIG_IGN)
let delegate = AppDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
