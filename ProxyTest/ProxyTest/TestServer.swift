import Network
import Foundation
import Combine

enum SlotState {
    case disconnected
    case free
    case busy(String)
}

// Thread-safe byte counter (touched from background network queues)
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _up = 0      // bytes Mac → internet (upload)
    private var _down = 0    // bytes internet → Mac (download)
    func addUp(_ n: Int)   { lock.lock(); _up += n;   lock.unlock() }
    func addDown(_ n: Int) { lock.lock(); _down += n; lock.unlock() }
    func reset()           { lock.lock(); _up = 0; _down = 0; lock.unlock() }
    var snapshot: (up: Int, down: Int) {
        lock.lock(); defer { lock.unlock() }; return (_up, _down)
    }
}

// Per-slot byte counter for the slot's current connection
final class SlotBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [Int]
    init(_ n: Int) { bytes = Array(repeating: 0, count: n) }
    func add(_ i: Int, _ n: Int) { lock.lock(); if i < bytes.count { bytes[i] += n }; lock.unlock() }
    func reset(_ i: Int)         { lock.lock(); if i < bytes.count { bytes[i] = 0 }; lock.unlock() }
    func resetAll()              { lock.lock(); for i in bytes.indices { bytes[i] = 0 }; lock.unlock() }
    var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return bytes }
}

@MainActor
class TestServer: ObservableObject {
    @Published var log: [String] = []
    @Published var isRunning = false
    @Published var slotStates: [SlotState] = Array(repeating: .disconnected, count: 30)
    @Published var bytesUp = 0
    @Published var bytesDown = 0
    @Published var perSlotBytes: [Int] = Array(repeating: 0, count: 30)
    var bytesTotal: Int { bytesUp + bytesDown }

    var established: Int { slotStates.filter { if case .free = $0 { return true }; if case .busy = $0 { return true }; return false }.count }
    var free: Int       { slotStates.filter { if case .free = $0 { return true }; return false }.count }

    private let poolSize = 30
    private var tunnelConnections: [NWConnection] = []
    nonisolated let counter = ByteCounter()
    nonisolated let slotBytes = SlotBytes(30)
    private var statsTimer: Timer?

    func start() {
        isRunning = true
        log = []
        tunnelConnections.removeAll()
        slotStates = Array(repeating: .disconnected, count: poolSize)
        counter.reset()
        slotBytes.resetAll()
        bytesUp = 0
        bytesDown = 0
        perSlotBytes = Array(repeating: 0, count: poolSize)
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let snap = self.counter.snapshot
                self.bytesUp = snap.up
                self.bytesDown = snap.down
                self.perSlotBytes = self.slotBytes.snapshot
            }
        }
        log.append("Opening \(poolSize) tunnel slots to Mac...")
        for i in 0..<poolSize {
            openSlot(index: i)
        }
    }

    private nonisolated func openSlot(index: Int) {
        let tunnel = NWConnection(host: "172.20.10.2", port: 9999, using: .tcp)

        Task { @MainActor [weak self] in
            self?.tunnelConnections.append(tunnel)
        }

        tunnel.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor [weak self] in
                    self?.slotStates[index] = .free
                    self?.log.append("Slot \(index) connected to Mac")
                }
                self?.waitForConnect(tunnel: tunnel, index: index)
            case .failed(let e):
                Task { @MainActor [weak self] in
                    self?.slotStates[index] = .disconnected
                    self?.log.append("Slot \(index) failed: \(e)")
                    self?.tunnelConnections.removeAll { $0 === tunnel }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    self?.openSlot(index: index)
                }
            case .cancelled:
                Task { @MainActor [weak self] in
                    self?.slotStates[index] = .disconnected
                    self?.tunnelConnections.removeAll { $0 === tunnel }
                    guard self?.isRunning == true else { return }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        self?.openSlot(index: index)
                    }
                }
            default: break
            }
        }
        tunnel.start(queue: .global())
    }

    private nonisolated func waitForConnect(tunnel: NWConnection, index: Int) {
        readLine(tunnel) { [weak self] line in
            let target = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard target.hasPrefix("CONNECT ") else { tunnel.cancel(); return }

            let hostPort = String(target.dropFirst("CONNECT ".count))
            let parts = hostPort.split(separator: ":")
            guard parts.count >= 2, let port = UInt16(parts.last!) else { tunnel.cancel(); return }
            let host = parts.dropLast().joined(separator: ":")

            self?.slotBytes.reset(index)
            Task { @MainActor [weak self] in
                self?.slotStates[index] = .busy(host)
                self?.log.append("─────────────────────")
                self?.log.append("Slot \(index) → \(host):\(port)")
                self?.log.append("Connecting via phone APN...")
            }

            let dest = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )

            dest.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor [weak self] in
                        self?.log.append("✓ Slot \(index) connected to \(host)")
                    }
                    tunnel.send(content: Data("CONNECTED\n".utf8), completion: .contentProcessed { _ in
                        var finished = false
                        let finish = {
                            if !finished {
                                finished = true
                                Task { @MainActor [weak self] in
                                    self?.log.append("✓ Slot \(index) done")
                                }
                                dest.cancel()
                                tunnel.cancel()
                            }
                        }
                        self?.pipe(from: tunnel, to: dest, slot: index, isDownload: false, onDone: finish)
                        self?.pipe(from: dest, to: tunnel, slot: index, isDownload: true, onDone: finish)
                    })
                case .failed(let e):
                    Task { @MainActor [weak self] in
                        self?.log.append("✗ Slot \(index) failed to reach \(host): \(e)")
                    }
                    tunnel.send(content: Data("FAILED\n".utf8), completion: .idempotent)
                    tunnel.cancel()
                default: break
                }
            }
            dest.start(queue: .global())
        }
    }

    private nonisolated func pipe(from: NWConnection, to: NWConnection, slot: Int, isDownload: Bool, onDone: @escaping () -> Void) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
                if isDownload { self?.counter.addDown(data.count) }
                else          { self?.counter.addUp(data.count) }
                self?.slotBytes.add(slot, data.count)
            }
            if isComplete || error != nil { onDone() }
            else { self?.pipe(from: from, to: to, slot: slot, isDownload: isDownload, onDone: onDone) }
        }
    }

    private nonisolated func readLine(_ conn: NWConnection, buffer: Data = Data(), completion: @escaping (String) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, error in
            guard let byte = data?.first, error == nil else { return }
            if byte == UInt8(ascii: "\n") {
                completion(String(data: buffer, encoding: .utf8) ?? "")
            } else {
                var buf = buffer; buf.append(byte)
                self?.readLine(conn, buffer: buf, completion: completion)
            }
        }
    }

    func stop() {
        isRunning = false
        statsTimer?.invalidate()
        statsTimer = nil
        slotStates = Array(repeating: .disconnected, count: poolSize)
        log = ["Stopping — closing all slots..."]
        tunnelConnections.forEach { $0.cancel() }
        tunnelConnections.removeAll()
        log.append("Stopped ✓")
    }
}
