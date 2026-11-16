import AppKit
import Foundation
import Network

final class SystemMonitor: @unchecked Sendable {
    private let onSystemWake: @Sendable () -> Void
    private let onNetworkRestored: @Sendable () -> Void

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.gmailpushbridge.netmonitor", qos: .utility)
    private var lastPathStatus: NWPath.Status?
    private var lastInterfaceSignature: String?

    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    init(
        onSystemWake: @escaping @Sendable () -> Void,
        onNetworkRestored: @escaping @Sendable () -> Void
    ) {
        self.onSystemWake = onSystemWake
        self.onNetworkRestored = onNetworkRestored
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [onSystemWake] _ in
            onSystemWake()
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = path.availableInterfaces.map(\.name).joined(separator: ",")
            let previousStatus = self.lastPathStatus
            let previousSignature = self.lastInterfaceSignature

            self.lastPathStatus = path.status
            self.lastInterfaceSignature = signature

            guard previousStatus != nil else { return }

            if path.status == .satisfied {
                if previousStatus != .satisfied || (previousSignature != nil && previousSignature != signature) {
                    self.onNetworkRestored()
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let wakeObserver {
            nc.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let sleepObserver {
            nc.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        pathMonitor.cancel()
    }
}
