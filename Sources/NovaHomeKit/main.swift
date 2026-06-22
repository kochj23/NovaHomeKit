import Foundation
import HomeKit
import Network

/// NovaHomeKit — Lightweight HomeKit query server for Nova.
/// Exposes a local HTTP API on port 37433 so Nova can query HomeKit without
/// launching HomekitControl or doing a network scan.
///
/// Endpoints:
///   GET /api/accessories  → JSON array of all accessories with room, services, characteristics
///   GET /api/status       → health check
///
/// Written by Jordan Koch.

// MARK: - HomeKit Manager

class HomeKitQueryServer: NSObject, HMHomeManagerDelegate {
    static let shared = HomeKitQueryServer()
    private let manager = HMHomeManager()
    private var listener: NWListener?
    private var homesReady = false
    private var cachedAccessoriesJSON = "[]"

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        startHTTP()
    }

    // MARK: - HMHomeManagerDelegate

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        homesReady = true
        let allAccessories = manager.homes.flatMap { $0.accessories }
        NSLog("[NovaHomeKit] HomeKit ready: \(manager.homes.count) home(s), \(allAccessories.count) accessories")

        let names = allAccessories.map { $0.name }
        let jsonStr = "[" + names.map { name in
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ",") + "]"

        cachedAccessoriesJSON = jsonStr
        try? jsonStr.write(toFile: "/tmp/novahomekit_accessories.json", atomically: true, encoding: .utf8)
        NSLog("[NovaHomeKit] Cache: \(names.count) names, \(jsonStr.count) bytes")
    }

    // MARK: - HTTP Server

    private func startHTTP() {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: 37433)
            listener?.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener?.stateUpdateHandler = { state in
                if case .ready = state { NSLog("[NovaHomeKit] HTTP server ready on port 37433") }
            }
            listener?.start(queue: .main)
        } catch {
            NSLog("[NovaHomeKit] Failed to start HTTP server: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: .main)
        receive(conn, Data())
    }

    private func receive(_ conn: NWConnection, _ buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            var b = buf
            if let d = data { b.append(d) }
            if let req = Self.parseRequest(b) {
                guard let resp = self?.route(req), let respData = resp.data(using: .utf8) else {
                    conn.cancel()
                    return
                }
                conn.send(content: respData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    // finalMessage signals EOF to the TCP stack — client will see connection close
                })
            } else if !done {
                self?.receive(conn, b)
            } else {
                conn.cancel()
            }
        }
    }

    private func route(_ req: (method: String, path: String)) -> String {
        let parts = req.path.components(separatedBy: "?")
        let path = parts.first ?? req.path
        let query = parts.count > 1 ? parts[1] : ""

        switch (req.method, path) {
        case ("GET", "/api/status"):
            return json(200, ["status": "ok", "app": "NovaHomeKit", "port": 37433, "homesReady": homesReady, "accessoryCount": manager.homes.flatMap { $0.accessories }.count] as [String: Any])

        case ("GET", "/api/accessories"):
            return http(200, cachedAccessoriesJSON, "application/json")

        // List all HomeKit scenes (action sets) by name.
        case ("GET", "/api/scenes"):
            let names = manager.homes.flatMap { $0.actionSets }.map { $0.name }
            let body = "[" + names.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",") + "]"
            return http(200, body, "application/json")

        // Execute a HomeKit scene by name: /api/scenes/execute?name=<scene>
        case ("GET", "/api/scenes/execute"), ("POST", "/api/scenes/execute"):
            guard let name = Self.queryValue(query, "name"), !name.isEmpty else {
                return json(400, ["error": "missing ?name="] as [String: Any])
            }
            let target = name.folding(options: .caseInsensitive, locale: nil)
            for home in manager.homes {
                if let set = home.actionSets.first(where: {
                    $0.name.folding(options: .caseInsensitive, locale: nil) == target
                }) {
                    home.executeActionSet(set) { error in
                        if let error = error {
                            NSLog("[NovaHomeKit] executeActionSet '\(name)' failed: \(error.localizedDescription)")
                        } else {
                            NSLog("[NovaHomeKit] executed scene '\(name)'")
                        }
                    }
                    return json(200, ["status": "executed", "scene": name] as [String: Any])
                }
            }
            return json(404, ["error": "scene not found: \(name)"] as [String: Any])

        default:
            return json(404, ["error": "Not found: \(req.method) \(path)"] as [String: Any])
        }
    }

    private func jsonEscape(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func queryValue(_ query: String, _ key: String) -> String? {
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == key {
                let v = kv[1].replacingOccurrences(of: "+", with: " ")
                return v.removingPercentEncoding ?? v
            }
        }
        return nil
    }

    private func json(_ status: Int, _ d: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: .prettyPrinted),
              let body = String(data: data, encoding: .utf8) else { return http(500, "") }
        return http(status, body, "application/json")
    }

    private func http(_ status: Int, _ body: String, _ ct: String = "text/plain") -> String {
        let statusText = [200: "OK", 404: "Not Found", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Unknown"
        return "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(ct); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
    }

    private static func parseRequest(_ data: Data) -> (method: String, path: String)? {
        guard let raw = String(data: data, encoding: .utf8), raw.contains("\r\n\r\n"),
              let firstLine = raw.components(separatedBy: "\r\n").first else { return nil }
        let tokens = firstLine.components(separatedBy: " ")
        guard tokens.count >= 2 else { return nil }
        return (tokens[0], tokens[1])
    }
}

// MARK: - App Entry Point

let server = HomeKitQueryServer.shared
server.start()
NSLog("[NovaHomeKit] Started — HomeKit initializing...")
RunLoop.main.run()
