import AppKit
import Foundation
import Network

final class SystemMonitor: @unchecked Sendable {
    private let onSystemWake: @Sendable () -> Void
    private let onNetworkRestored: @Sendable () -> Void
    private let onMailLaunched: @Sendable () -> Void
    private let onMailTerminated: @Sendable () -> Void

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.gmailpushbridge.netmonitor", qos: .utility)
    private var lastPathStatus: NWPath.Status?
    private var lastInterfaceSignature: String?

    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var mailLaunchObserver: NSObjectProtocol?
    private var mailTerminateObserver: NSObjectProtocol?

    init(
        onSystemWake: @escaping @Sendable () -> Void,
        onNetworkRestored: @escaping @Sendable () -> Void,
        onMailLaunched: @escaping @Sendable () -> Void = {},
        onMailTerminated: @escaping @Sendable () -> Void = {}
    ) {
        self.onSystemWake = onSystemWake
        self.onNetworkRestored = onNetworkRestored
        self.onMailLaunched = onMailLaunched
        self.onMailTerminated = onMailTerminated
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

        mailLaunchObserver = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [onMailLaunched] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AppleMailBridge.mailBundleIdentifier else {
                return
            }
            onMailLaunched()
        }

        mailTerminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [onMailTerminated] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AppleMailBridge.mailBundleIdentifier else {
                return
            }
            onMailTerminated()
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
        if let mailLaunchObserver {
            nc.removeObserver(mailLaunchObserver)
            self.mailLaunchObserver = nil
        }
        if let mailTerminateObserver {
            nc.removeObserver(mailTerminateObserver)
            self.mailTerminateObserver = nil
        }
        pathMonitor.cancel()
    }
}
