#if LIVE_CONTAINER_NATIVE
import Foundation
import Network
import Combine
import UIKit
import Darwin

struct SignedAppInstallInfo: Sendable {
    let bundleIdentifier: String
    let version: String
    let displayName: String
}

@MainActor
final class LocalInstallServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var installURL: URL?
    @Published private(set) var manifestURL: URL?
    /// The system installer URL. Opening this directly avoids relying on a
    /// Safari JavaScript redirect, which can be blocked during handoff.
    @Published private(set) var otaURL: URL?
    /// The address that is embedded in the manifest and handed to iOS.
    /// Loopback is useful for Safari, but the system installer can resolve
    /// the device's LAN address more reliably after Workspace is backgrounded.
    @Published private(set) var hostAddress: String?
    /// Remaining time reported by UIKit after the app is backgrounded. A
    /// finite value is the system's best estimate, not a guaranteed lease.
    @Published private(set) var backgroundTimeRemaining: TimeInterval = .greatestFiniteMagnitude
    @Published private(set) var backgroundExecutionExpired = false

    private var listener: NWListener?
    private var packageURL: URL?
    private var appInfo: SignedAppInstallInfo?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var deliveryCleanupTask: Task<Void, Never>?
    private var advertisedHost = "127.0.0.1"

    func start(packageURL: URL, appInfo: SignedAppInstallInfo) {
        stop()
        self.packageURL = packageURL
        self.appInfo = appInfo
        self.advertisedHost = Self.preferredHostAddress() ?? "127.0.0.1"
        backgroundExecutionExpired = false
        // Request the UIKit assertion while the app is still foregrounded.
        // Apple warns that requesting it only after suspension has started can
        // be too late for the system to grant it.
        beginBackgroundTask()
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue ?? 0
                        guard port > 0 else {
                            self.statusMessage = "The local installer could not acquire a port."
                            return
                        }
                        self.isRunning = true
                        self.hostAddress = self.advertisedHost
                        if self.advertisedHost == "127.0.0.1" {
                            self.statusMessage = "Local installer is running on 127.0.0.1:" + String(port) + ". Connect the iPhone to Wi-Fi to enable Home Screen installation."
                        } else {
                            self.statusMessage = "Local installer is running on " + self.advertisedHost + ":" + String(port) + "."
                        }
                        self.installURL = self.baseURL(port: port, path: "/install")
                        self.manifestURL = self.baseURL(port: port, path: "/manifest.plist")
                        if self.advertisedHost != "127.0.0.1", let manifestURL = self.manifestURL {
                            self.otaURL = Self.makeOTAURL(manifestURL)
                        }
                    case .failed(let error):
                        self.statusMessage = "Local installer stopped: " + error.localizedDescription
                        self.stop()
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handle(connection)
                }
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            statusMessage = "Could not start the local installer: " + error.localizedDescription
            // `start` acquires the UIKit assertion before creating the
            // listener. Release it if listener construction fails.
            stop()
            statusMessage = "Could not start the local installer: " + error.localizedDescription
        }
    }

    func stop() {
        deliveryCleanupTask?.cancel()
        deliveryCleanupTask = nil
        endBackgroundTask()
        listener?.cancel()
        listener = nil
        isRunning = false
        installURL = nil
        manifestURL = nil
        otaURL = nil
        hostAddress = nil
        backgroundTimeRemaining = .greatestFiniteMagnitude
        backgroundExecutionExpired = false
    }

    /// Allows the hosting UI to surface a handoff failure without exposing
    /// the published state for arbitrary mutation.
    func reportStatus(_ message: String) {
        statusMessage = message
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        // UIKit grants a short, system-controlled grace period when the app
        // leaves the foreground. This is the supported API for finishing the
        // manifest and IPA transfer; no background entitlement extends it.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Workspace IPA installation") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.backgroundExecutionExpired = true
                self.backgroundTimeRemaining = 0
                self.statusMessage = "iOS background time expired before the IPA finished downloading. Use the HTTPS Workspace Pi handoff."
                self.endBackgroundTask()
            }
        }
        guard backgroundTask != .invalid else {
            backgroundExecutionExpired = true
            statusMessage = "iOS did not grant background time for the local installer. Use the HTTPS Workspace Pi handoff."
            return
        }
        backgroundTimeRemaining = UIApplication.shared.backgroundTimeRemaining
        statusMessage = "Local installer has UIKit background time to finish the handoff."
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        backgroundTimeRemaining = .greatestFiniteMagnitude
    }

    private func handle(_ connection: NWConnection) {
        refreshBackgroundTimeRemaining()
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            Task { @MainActor in
                let response = self.response(for: path)
                let isPackageResponse = path.split(separator: "?").first.map(String.init) == "/app.ipa"
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                    guard isPackageResponse else { return }
                    Task { @MainActor in
                        self.statusMessage = "The signed IPA was delivered to the iOS installer."
                        self.scheduleDeliveryCleanup()
                    }
                })
            }
        }
    }

    private func scheduleDeliveryCleanup() {
        guard deliveryCleanupTask == nil else { return }
        // Network.framework's contentProcessed callback only means it
        // accepted the bytes. Keep the listener and assertion alive during
        // the iOS installer handoff, then release them after a short window.
        deliveryCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func response(for path: String) -> Data {
        refreshBackgroundTimeRemaining()
        guard let packageURL, let appInfo else { return httpResponse(status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8)) }
        switch path.split(separator: "?").first.map(String.init) {
        case "/install":
            let port = listener?.port?.rawValue ?? 0
            let manifestURL = baseURL(port: port, path: "/manifest.plist")?.absoluteString ?? "http://127.0.0.1:" + String(port) + "/manifest.plist"
            let redirect = Self.makeOTAURL(URL(string: manifestURL)!)?.absoluteString ?? "itms-services://?action=download-manifest&url=" + manifestURL
            let html = "<html><head><meta name=\"viewport\" content=\"width=device-width\"></head><body><p>Opening iOS installation...</p><script>window.location.href=\"" + redirect + "\";</script></body></html>"
            return httpResponse(status: "200 OK", type: "text/html; charset=utf-8", body: Data(html.utf8))
        case "/manifest.plist":
            let manifest: [String: Any] = [
                "items": [[
                    "assets": [["kind": "software-package", "url": baseURL(port: listener?.port?.rawValue ?? 0, path: "/app.ipa")?.absoluteString ?? "http://127.0.0.1:" + String(listener?.port?.rawValue ?? 0) + "/app.ipa"]],
                    "metadata": [
                        "bundle-identifier": appInfo.bundleIdentifier,
                        "bundle-version": appInfo.version,
                        "kind": "software",
                        "title": appInfo.displayName
                    ]
                ]]
            ]
            let data = (try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)) ?? Data()
            return httpResponse(status: "200 OK", type: "text/xml", body: data)
        case "/app.ipa":
            guard let data = try? Data(contentsOf: packageURL) else { return httpResponse(status: "404 Not Found", type: "text/plain", body: Data("Package not found".utf8)) }
            return httpResponse(status: "200 OK", type: "application/octet-stream", body: data)
        default:
            return httpResponse(status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func refreshBackgroundTimeRemaining() {
        guard backgroundTask != .invalid else { return }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        if remaining.isFinite {
            backgroundTimeRemaining = max(0, remaining)
        }
    }

    private func httpResponse(status: String, type: String, body: Data) -> Data {
        let contentLength = String(body.count)
        let headerText = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(contentLength)\r\nConnection: close\r\n\r\n"
        var header = headerText.data(using: .utf8) ?? Data()
        header.append(body)
        return header
    }

    private func baseURL(port: UInt16, path: String) -> URL? {
        URL(string: "http://" + advertisedHost + ":" + String(port) + path)
    }

    /// Returns a non-loopback IPv4 address when the device has one. The
    /// system installer may fetch the manifest from a separate service that
    /// cannot reach the app's loopback interface, while both services can
    /// reach the device over its active Wi-Fi or cellular interface.
    private static func preferredHostAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }

        var candidates: [(priority: Int, address: String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let flags = interface.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let socketAddress = interface.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var address = pointer.pointee.sin_addr
                hostBuffer.withUnsafeMutableBufferPointer { buffer in
                    _ = inet_ntop(AF_INET, &address, buffer.baseAddress, socklen_t(buffer.count))
                }
            }
            let address = String(cString: hostBuffer)
            guard !address.isEmpty, address != "127.0.0.1", !address.hasPrefix("169.254.") else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            let priority: Int
            if name == "en0" { priority = 0 }
            else if name.hasPrefix("pdp_ip") { priority = 1 }
            else { priority = 2 }
            candidates.append((priority, address))
        }
        return candidates.sorted { $0.priority < $1.priority }.first?.address
    }

    private static func makeOTAURL(_ manifestURL: URL) -> URL? {
        // Keep the nested manifest URL as one escaped query value.
        guard var components = URLComponents(string: "itms-services://") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: manifestURL.absoluteString)
        ]
        return components.url
    }
}
#endif
