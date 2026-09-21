#if LIVE_CONTAINER_NATIVE
import Foundation
import Network
import Combine

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

    private var listener: NWListener?
    private var packageURL: URL?
    private var appInfo: SignedAppInstallInfo?

    func start(packageURL: URL, appInfo: SignedAppInstallInfo) {
        stop()
        self.packageURL = packageURL
        self.appInfo = appInfo
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
                        self.statusMessage = "Local installer is running on 127.0.0.1:" + String(port) + "."
                        self.installURL = URL(string: "http://127.0.0.1:" + String(port) + "/install")
                        self.manifestURL = URL(string: "http://127.0.0.1:" + String(port) + "/manifest.plist")
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
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        installURL = nil
        manifestURL = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            Task { @MainActor in
                let response = self.response(for: path)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func response(for path: String) -> Data {
        guard let packageURL, let appInfo else { return httpResponse(status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8)) }
        switch path.split(separator: "?").first.map(String.init) {
        case "/install":
            let port = listener?.port?.rawValue ?? 0
            let redirect = "itms-services://?action=download-manifest&url=http://127.0.0.1:" + String(port) + "/manifest.plist"
            let html = "<html><head><meta name=\"viewport\" content=\"width=device-width\"></head><body><p>Opening iOS installation...</p><script>window.location.href=\"" + redirect + "\";</script></body></html>"
            return httpResponse(status: "200 OK", type: "text/html; charset=utf-8", body: Data(html.utf8))
        case "/manifest.plist":
            let manifest: [String: Any] = [
                "items": [[
                    "assets": [["kind": "software-package", "url": "http://127.0.0.1:" + String(listener?.port?.rawValue ?? 0) + "/app.ipa"]],
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

    private func httpResponse(status: String, type: String, body: Data) -> Data {
        var header = "HTTP/1.1 " + status + "\r\nContent-Type: " + type + "\r\nContent-Length: " + String(body.count) + "\r\nConnection: close\r\n\r\n"
            .data(using: .utf8) ?? Data()
        header.append(body)
        return header
    }
}
#endif
