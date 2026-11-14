import AppKit
import Darwin
import IOKit
import ServiceManagement
import SwiftUI

struct StressError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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

// MARK: - Sensors

/// Layout of the AppleSMC user client's request and reply, 80 bytes.
struct SMCKeyData {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct Limits {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var mem: UInt32 = 0
    }
    struct Info {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var attributes: UInt8 = 0
    }
    var key: UInt32 = 0
    var version = Version()
    var limits = Limits()
    var info = Info()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Reads what the Mac reports about itself. None of this needs root.
final class Sensors {
    private var smc: io_connect_t = 0
    private var lastTicks: [UInt32]?

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        if IOServiceOpen(service, mach_task_self_, 0, &smc) != kIOReturnSuccess { smc = 0 }
        IOObjectRelease(service)
    }

    /// Total system power in watts, from the SMC key PSTR.
    func systemPower() -> Double? {
        guard smc != 0 else { return nil }
        let key = "PSTR".utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var query = SMCKeyData()
        query.key = key
        query.data8 = 9
        guard let info = call(&query), info.info.dataSize == 4 else { return nil }
        let float = "flt ".utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard info.info.dataType == float else { return nil }
        var read = SMCKeyData()
        read.key = key
        read.info.dataSize = 4
        read.data8 = 5
        guard let reply = call(&read) else { return nil }
        let watts = withUnsafeBytes(of: reply.bytes) { $0.loadUnaligned(as: Float.self) }
        guard watts.isFinite, watts > 0, watts < 2000 else { return nil }
        return Double(watts)
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.size
        let status = IOConnectCallStructMethod(smc, 2, &input, size, &output, &size)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    /// Share of all CPU time that was not idle since the previous call, 0...100.
    func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { lastTicks = ticks }
        guard let lastTicks else { return nil }
        var delta: [Double] = []
        for index in 0..<4 { delta.append(Double(ticks[index] &- lastTicks[index])) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return 100 * (total - delta[Int(CPU_STATE_IDLE)]) / total
    }

    /// The GPU's own "Device Utilization %", the number Activity Monitor plots.
    func gpuLoad() -> Double? {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard status == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let property = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
            if let stats = property?.takeRetainedValue() as? [String: Any],
               let value = stats["Device Utilization %"] as? NSNumber {
                best = max(best ?? 0, value.doubleValue)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best
    }
}

// MARK: - Workers

enum Kind: String, CaseIterable {
    case cpu
    case gpu

    var title: String { self == .cpu ? "CPU" : "GPU" }
    var symbol: String { self == .cpu ? "cpu" : "square.3.layers.3d" }
}

/// One `heat-worker` process. Its duty level goes down a pipe to its stdin,
/// and closing that pipe is what makes it exit.
final class Worker {
    private let process = Process()
    private let input = Pipe()
    private var stopping = false

    var pid: Int32 { process.processIdentifier }

    init(kind: Kind, level: Double, onUnexpectedExit: @escaping () -> Void) throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/heat-worker")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw StressError(message: "heat-worker is missing from the app")
        }
        guard let sink = FileHandle(forWritingAtPath: "/dev/null") else {
            throw StressError(message: "Could not open /dev/null")
        }
        process.executableURL = url
        process.arguments = [kind.rawValue, String(format: "%.4f", level)]
        process.qualityOfService = .userInitiated
        process.standardInput = input
        process.standardOutput = sink
        process.standardError = sink
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                onUnexpectedExit()
            }
        }
        try process.run()
    }

    func send(_ level: Double) {
        guard let line = String(format: "%.4f\n", level).data(using: .utf8) else { return }
        try? input.fileHandleForWriting.write(contentsOf: line)
    }

    func stop() {
        stopping = true
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate() }
        let hardDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < hardDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

// MARK: - Model

struct Channel {
    var on = false
    /// What the user asked for, in percent of utilization.
    var target: Double
    /// Duty level that reaches the target, 0...1, before the power cap scales it.
    var duty = 0.0
    /// Measured utilization, in percent.
    var load: Double?
    /// Samples to skip before trimming again, so stale readings are ignored.
    var settle = 0
}

/// Everything the app does. Used from the main thread only.
final class HeatModel: ObservableObject {
    static let shared = HeatModel()
    static let targetRange: ClosedRange<Double> = 10...100
    static let capRange: ClosedRange<Double> = 20...200
    private static let minScale = 0.02

    @Published private(set) var cpu: Channel
    @Published private(set) var gpu: Channel
    @Published private(set) var capOn: Bool
    @Published private(set) var capWatts: Double
    @Published private(set) var power: Double?
    /// Share of the targets the power cap currently allows, 0...1.
    @Published private(set) var scale = 1.0
    @Published private(set) var capBelowIdle = false
    @Published private(set) var error: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    var panelVisible = false {
        didSet { if panelVisible { sample() } }
    }

    private let sensors = Sensors()
    private let defaults = UserDefaults.standard
    private var workers: [Kind: Worker] = [:]
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private var idlePower: Double?
    private var lastStop = Date.distantPast
    private var holdoff = 0

    private init() {
        let stored = { (key: String, fallback: Double, range: ClosedRange<Double>) -> Double in
            let value = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
            return min(max(value, range.lowerBound), range.upperBound)
        }
        cpu = Channel(target: stored("cpuTarget", 100, Self.targetRange))
        gpu = Channel(target: stored("gpuTarget", 100, Self.targetRange))
        capWatts = stored("capWatts", 60, Self.capRange)
        capOn = UserDefaults.standard.bool(forKey: "capOn")
        power = sensors.systemPower()
        _ = sensors.cpuLoad()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var anyOn: Bool { cpu.on || gpu.on }
    var canMeasurePower: Bool { power != nil }
    var throttled: Bool { capOn && anyOn && scale < 0.995 }

    func channel(_ kind: Kind) -> Channel { kind == .cpu ? cpu : gpu }

    /// Level sent to the worker: the trimmed duty, scaled down by the power cap.
    private func level(_ kind: Kind) -> Double {
        min(max(channel(kind).duty * scale, 0.005), 1)
    }

    private func push(_ kind: Kind) {
        workers[kind]?.send(level(kind))
    }

    private func path(_ kind: Kind) -> ReferenceWritableKeyPath<HeatModel, Channel> {
        kind == .cpu ? \.cpu : \.gpu
    }

    // MARK: Commands

    func setOn(_ kind: Kind, _ on: Bool) {
        if on {
            do {
                try start(kind)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        } else {
            stop(kind)
            error = nil
        }
    }

    func start(_ kind: Kind) throws {
        guard !channel(kind).on else { return }
        if !anyOn {
            // The power reading trails the load, so only trust it as "idle" once it has settled.
            if Date().timeIntervalSince(lastStop) > 6, let reading = sensors.systemPower() {
                idlePower = reading
            }
            // With a cap set, come up low and climb to it instead of overshooting.
            scale = capOn && canMeasurePower ? 0.3 : 1
            holdoff = 3
            capBelowIdle = false
        }
        self[keyPath: path(kind)].duty = channel(kind).target / 100
        let worker = try Worker(kind: kind, level: level(kind)) { [weak self] in
            guard let self, self.workers[kind] != nil else { return }
            self.stop(kind)
            self.error = "\(kind.title) load stopped unexpectedly"
        }
        workers[kind] = worker
        self[keyPath: path(kind)].on = true
        self[keyPath: path(kind)].settle = 3
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "CPU and GPU stress"
            )
        }
        writePids()
    }

    func stop(_ kind: Kind) {
        guard let worker = workers.removeValue(forKey: kind) else { return }
        worker.stop()
        self[keyPath: path(kind)].on = false
        self[keyPath: path(kind)].duty = 0
        if !anyOn {
            lastStop = Date()
            scale = 1
            capBelowIdle = false
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }
        writePids()
    }

    func stopAll() {
        for kind in Kind.allCases { stop(kind) }
    }

    func setTarget(_ kind: Kind, _ percent: Double) {
        let range = Self.targetRange
        let value = min(max((percent / 5).rounded() * 5, range.lowerBound), range.upperBound)
        let previous = channel(kind).target
        guard value != previous else { return }
        self[keyPath: path(kind)].target = value
        defaults.set(value, forKey: kind.rawValue + "Target")
        guard channel(kind).on else { return }
        // Shift the duty by the change and keep what trimming has learned so far.
        let duty = min(max(channel(kind).duty + (value - previous) / 100, 0.005), 1)
        self[keyPath: path(kind)].duty = value >= 99.5 ? 1 : duty
        self[keyPath: path(kind)].settle = 2
        push(kind)
    }

    func setCapOn(_ on: Bool) {
        capOn = on
        defaults.set(on, forKey: "capOn")
        if !on { setScale(1) }
        holdoff = 0
        capBelowIdle = false
    }

    func setCapWatts(_ watts: Double) {
        let range = Self.capRange
        let value = min(max((watts / 5).rounded() * 5, range.lowerBound), range.upperBound)
        guard value != capWatts else { return }
        capWatts = value
        defaults.set(value, forKey: "capWatts")
        holdoff = min(holdoff, 1)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func reportError(_ message: String) {
        error = message
    }

    // MARK: Control loop

    private func setScale(_ value: Double) {
        let next = min(max(value, Self.minScale), 1)
        guard next != scale else { return }
        scale = next
        for kind in Kind.allCases where channel(kind).on {
            self[keyPath: path(kind)].settle = 3
            push(kind)
        }
    }

    private func sample() {
        power = sensors.systemPower()
        cpu.load = sensors.cpuLoad()
        gpu.load = sensors.gpuLoad()
    }

    private func tick() {
        guard anyOn || panelVisible else { return }
        sample()
        guard anyOn else { return }
        applyCap()
        for kind in Kind.allCases { trim(kind) }
    }

    /// Moves `scale` so that total system power settles just under the cap.
    /// The power reading trails the load by a few seconds, so each change is
    /// followed by a pause before the next one.
    private func applyCap() {
        guard capOn, let power else { return }
        holdoff -= 1
        guard holdoff <= 0 else { return }
        let floor = idlePower ?? 0
        let room = capWatts - floor
        let used = max(power - floor, 1)
        if power > capWatts {
            capBelowIdle = scale <= Self.minScale * 1.01
            setScale(room > 2 ? scale * (room * 0.95) / used : Self.minScale)
            holdoff = 4
        } else if power < capWatts * 0.9, scale < 1 {
            capBelowIdle = false
            // Power grows faster than the duty level, so climb in small steps.
            let wanted = pow(max(room * 0.95, 1) / used, 0.6)
            let most = power < capWatts * 0.7 ? 1.4 : 1.15
            setScale(scale * min(max(wanted, 1.02), most))
            holdoff = 4
        } else {
            capBelowIdle = false
        }
    }

    /// Nudges a worker's duty level until the measured utilization matches the
    /// target. Other software on the Mac counts toward the measurement. While
    /// the power cap is holding the load back, the duty is left alone.
    private func trim(_ kind: Kind) {
        var state = channel(kind)
        guard state.on else { return }
        if state.settle > 0 {
            self[keyPath: path(kind)].settle = state.settle - 1
            return
        }
        guard !throttled else { return }
        let goal = state.target / 100
        var duty = goal
        if goal < 0.995, let load = state.load {
            duty = state.duty + 0.5 * (goal - load / 100)
        }
        duty = min(max(duty, 0.005), 1)
        guard abs(duty - state.duty) > 0.002 else { return }
        state.duty = duty
        self[keyPath: path(kind)] = state
        push(kind)
    }

    // MARK: Leftover processes

    private var pidFile: URL? {
        (try? supportDirectory())?.appendingPathComponent("pids")
    }

    private func writePids() {
        guard let pidFile else { return }
        if workers.isEmpty {
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        let body = workers.values.map { String($0.pid) }.joined(separator: "\n") + "\n"
        try? body.write(to: pidFile, atomically: true, encoding: .utf8)
    }

    /// Kills load processes a crashed earlier run left behind, and only those.
    func reapStale() {
        guard let pidFile, let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let pid = Int32(line), pid > 1, let path = executablePath(pid: pid) else { continue }
            let name = (path as NSString).lastPathComponent
            if ["heat-worker", "gpu-heat", "yes"].contains(name) {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    // MARK: Control socket

    func handle(_ command: String) -> String {
        let words = command.lowercased().split(separator: " ").map(String.init)
        guard let verb = words.first else { return "err empty\n" }
        let rest = Array(words.dropFirst())
        switch verb {
        case "start":
            var kinds = Kind.allCases
            var percent: Double?
            for word in rest {
                if let kind = Kind(rawValue: word) {
                    kinds = [kind]
                } else if let value = Double(word) {
                    percent = value
                } else {
                    return "err unknown\n"
                }
            }
            do {
                for kind in kinds {
                    if let percent { setTarget(kind, percent) }
                    try start(kind)
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
                return "err \(error.localizedDescription)\n"
            }
        case "stop":
            if rest.isEmpty {
                stopAll()
            } else if rest.count == 1, let kind = Kind(rawValue: rest[0]) {
                stop(kind)
            } else {
                return "err unknown\n"
            }
            error = nil
        case "cpu", "gpu":
            guard let kind = Kind(rawValue: verb), rest.count == 1, let percent = Double(rest[0]) else {
                return "err usage: \(verb) <percent>\n"
            }
            setTarget(kind, percent)
        case "limit":
            guard rest.count == 1 else { return "err usage: limit <watts>|off\n" }
            if rest[0] == "off" {
                setCapOn(false)
            } else if let watts = Double(rest[0]) {
                setCapWatts(watts)
                setCapOn(true)
            } else {
                return "err usage: limit <watts>|off\n"
            }
        case "status":
            break
        default:
            return "err unknown\n"
        }
        return statusLine()
    }

    private func statusLine() -> String {
        var parts = ["ok", anyOn ? "running" : "stopped"]
        for kind in Kind.allCases {
            let state = channel(kind)
            parts.append("\(kind.rawValue)=\(state.on ? String(Int(state.target)) : "off")")
        }
        parts.append("limit=\(capOn ? String(Int(capWatts)) : "off")")
        power = sensors.systemPower()
        if let power { parts.append(String(format: "power=%.0f", power)) }
        if throttled { parts.append(String(format: "scale=%.2f", scale)) }
        return parts.joined(separator: " ") + "\n"
    }
}

// MARK: - Control socket

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

// MARK: - Interface

struct Meter: View {
    /// Measured utilization, 0...100.
    let value: Double?
    /// Where the load is being steered, 0...100. Drawn as a notch.
    let goal: Double?
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(active ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color.secondary.opacity(0.45)))
                    .frame(width: max(4, width * min(max(value ?? 0, 0), 100) / 100))
                    .animation(.easeOut(duration: 0.6), value: value)
                if let goal, active {
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: 10)
                        .offset(x: min(max(width * goal / 100 - 1, 0), width - 2))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ChannelCard: View {
    @ObservedObject var model: HeatModel
    let kind: Kind

    var body: some View {
        let state = model.channel(kind)
        Card {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(state.on ? Color.orange : Color.secondary)
                    .frame(width: 18)
                Text(kind.title).font(.headline)
                Spacer()
                Toggle(kind.title + " load", isOn: Binding(
                    get: { model.channel(kind).on },
                    set: { model.setOn(kind, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.orange)
            }
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { model.channel(kind).target },
                        set: { model.setTarget(kind, $0) }
                    ),
                    in: HeatModel.targetRange
                )
                .controlSize(.small)
                .tint(.orange)
                .accessibilityLabel(kind.title + " target")
                Text("\(Int(state.target))%")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            Meter(value: state.load, goal: state.on && !model.throttled ? state.target : nil, active: state.on)
            Text(caption(state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func caption(_ state: Channel) -> String {
        let now = state.load.map { "Now \(Int($0.rounded()))%" } ?? "No reading"
        guard state.on else { return now + " · load off" }
        if model.throttled {
            return now + " · held below \(Int(state.target))% by the power cap"
        }
        return now + " · aiming at \(Int(state.target))%"
    }
}

struct CapCard: View {
    @ObservedObject var model: HeatModel

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.capOn ? Color.orange : Color.secondary)
                    .frame(width: 18)
                Text("Power cap").font(.headline)
                Spacer()
                Toggle("Power cap", isOn: Binding(
                    get: { model.capOn },
                    set: { model.setCapOn($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.orange)
                .disabled(!model.canMeasurePower)
            }
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { model.capWatts },
                        set: { model.setCapWatts($0) }
                    ),
                    in: HeatModel.capRange
                )
                .controlSize(.small)
                .tint(.orange)
                .disabled(!model.canMeasurePower)
                .accessibilityLabel("Power cap in watts")
                Text("\(Int(model.capWatts)) W")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        guard model.canMeasurePower else { return "This Mac does not report its power draw, so there is nothing to hold a cap against." }
        guard model.capOn else { return "Scales the load down to keep the whole Mac under a set wattage." }
        guard model.anyOn else { return "Load will start low and climb until the Mac draws \(Int(model.capWatts)) W." }
        if model.capBelowIdle { return "The Mac draws more than \(Int(model.capWatts)) W with the load at its minimum." }
        if model.throttled { return "Holding the load at \(Int((model.scale * 100).rounded()))% strength to stay under \(Int(model.capWatts)) W." }
        return "Under the cap. The load is running at its full targets."
    }
}

struct Panel: View {
    @ObservedObject var model: HeatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ChannelCard(model: model, kind: .cpu)
            ChannelCard(model: model, kind: .gpu)
            CapCard(model: model)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { model.panelVisible = true }
        .onDisappear { model.panelVisible = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.anyOn ? "flame.fill" : "flame")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(model.anyOn ? Color.white : Color.secondary)
                .frame(width: 34, height: 34)
                .background(
                    model.anyOn ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("HeatBar").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let power = model.power {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(power.rounded())) W")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("system power").font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 2)
    }

    private var summary: String {
        let active = Kind.allCases.filter { model.channel($0).on }
        guard !active.isEmpty else { return "Idle" }
        let parts = active.map { "\($0.title) \(Int(model.channel($0).target))%" }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Spacer()
            if model.anyOn {
                Button("Stop all") { model.stopAll() }
                    .controlSize(.small)
            }
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let model = HeatModel.shared
        model.reapStale()
        do {
            let socketPath = try supportDirectory().appendingPathComponent("control.sock").path
            let server = try ControlServer(path: socketPath)
            server.serve { command in
                DispatchQueue.main.sync { HeatModel.shared.handle(command) }
            }
            self.server = server
        } catch {
            model.reportError(error.localizedDescription)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        HeatModel.shared.stopAll()
        return .terminateNow
    }
}

@main
struct HeatBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = HeatModel.shared

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            Image(systemName: model.anyOn ? "flame.fill" : "flame")
                .accessibilityLabel(model.anyOn ? "HeatBar: stressing" : "HeatBar: idle")
        }
        .menuBarExtraStyle(.window)
    }
}
