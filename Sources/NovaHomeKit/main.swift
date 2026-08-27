import Foundation
import HomeKit
import Network

/// NovaHomeKit — Lightweight HomeKit query + control server for Nova.
/// Exposes a local HTTP API on port 37433 so Nova can query and drive HomeKit
/// without launching HomekitControl or doing a network scan.
///
/// Endpoints:
///   GET  /api/accessories                         → JSON array: room, services, characteristics (+values)
///   GET  /api/status                              → health check
///   GET  /api/scenes                              → JSON array of HomeKit scene (action set) names
///   GET|POST /api/scenes/execute?name=<scene>     → run a HomeKit scene via executeActionSet
///   GET|POST /api/accessories/power?name=<n>&on=<true|false> → set an accessory's Power State
///
/// Written by Jordan Koch.

// MARK: - HomeKit Manager

class HomeKitQueryServer: NSObject, HMHomeManagerDelegate {
    static let shared = HomeKitQueryServer()
    private let manager = HMHomeManager()
    private var listener: NWListener?
    private var homesReady = false

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
        NSLog("[NovaHomeKit] HomeKit ready: \(manager.homes.count) home(s), \(manager.homes.flatMap { $0.accessories }.count) accessories")
    }

    // MARK: - HTTP Server

    private func startHTTP() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 37433)
            listener = try NWListener(using: params)
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
        conn.start(queue: .main)
        receive(conn, Data())
    }

    private func receive(_ conn: NWConnection, _ buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            var b = buf
            if let d = data { b.append(d) }
            if let req = Self.parseRequest(b) {
                let resp = self?.route(req) ?? self?.http(503, "Not ready")
                conn.send(content: resp?.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            } else if !done {
                self?.receive(conn, b)
            } else {
                conn.cancel()
            }
        }
    }

    private func route(_ req: (method: String, path: String, headers: [String: String])) -> String {
        // DNS-rebinding protection: only serve loopback-addressed requests.
        guard Self.isAllowedHost(req.headers["host"]) else {
            return json(403, ["error": "forbidden host"] as [String: Any])
        }
        // Require the shared secret on every request.
        guard Self.authorized(req.headers["authorization"]) else {
            return json(401, ["error": "unauthorized"] as [String: Any])
        }

        let parts = req.path.components(separatedBy: "?")
        let path = parts.first ?? req.path
        let query = parts.count > 1 ? parts[1] : ""

        switch (req.method, path) {
        case ("GET", "/api/status"):
            return json(200, ["status": "ok", "app": "NovaHomeKit", "port": 37433, "homesReady": homesReady, "accessoryCount": manager.homes.flatMap { $0.accessories }.count] as [String: Any])

        case ("GET", "/api/accessories"):
            if !homesReady {
                return json(200, ["accessories": [], "note": "HomeKit still initializing"] as [String: Any])
            }
            var result: [[String: Any]] = []
            for home in manager.homes {
                let roomMap: [UUID: String] = {
                    var m: [UUID: String] = [:]
                    for room in home.rooms {
                        for acc in room.accessories { m[acc.uniqueIdentifier] = room.name }
                    }
                    return m
                }()
                for acc in home.accessories {
                    let services = acc.services.map { svc -> [String: Any] in
                        let chars = svc.characteristics.map { c -> [String: Any] in
                            var entry: [String: Any] = ["type": c.localizedDescription, "uuid": c.characteristicType]
                            // Guard against non-JSON-serializable values (e.g. Data/custom on FP2
                            // sensors) — those raise an NSException in JSONSerialization and crash
                            // the whole server. Pass primitives through; stringify anything else.
                            if let v = c.value {
                                if v is String || v is NSNumber {
                                    entry["value"] = v
                                } else {
                                    entry["value"] = String(describing: v)
                                }
                            }
                            return entry
                        }
                        return ["type": svc.serviceType, "name": svc.name, "characteristics": chars]
                    }
                    result.append([
                        "name": acc.name,
                        "room": roomMap[acc.uniqueIdentifier] ?? "Unknown",
                        "home": home.name,
                        "reachable": acc.isReachable,
                        "services": services
                    ] as [String: Any])
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
                  let body = String(data: data, encoding: .utf8) else {
                return http(500, "JSON error")
            }
            return http(200, body, "application/json")

        // List HomeKit scenes (action sets) by name.
        case ("GET", "/api/scenes"):
            let names = manager.homes.flatMap { $0.actionSets }.map { $0.name }
            let body = "[" + names.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",") + "]"
            return http(200, body, "application/json")

        // Execute a HomeKit scene by name: /api/scenes/execute?name=<scene>
        // State-changing → POST only (GET would be CSRF-able from a web page).
        case ("POST", "/api/scenes/execute"):
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
                            NSLog("[NovaHomeKit] scene '\(name)' failed: \(error.localizedDescription)")
                        } else {
                            NSLog("[NovaHomeKit] executed scene '\(name)'")
                        }
                    }
                    return json(200, ["status": "executed", "scene": name] as [String: Any])
                }
            }
            return json(404, ["error": "scene not found: \(name)"] as [String: Any])

        // Power an accessory on/off by name: /api/accessories/power?name=<accessory>&on=<true|false>
        // State-changing → POST only (GET would be CSRF-able from a web page).
        case ("POST", "/api/accessories/power"):
            guard let name = Self.queryValue(query, "name"), !name.isEmpty else {
                return json(400, ["error": "missing ?name="] as [String: Any])
            }
            let on = (Self.queryValue(query, "on") ?? "true").lowercased() != "false"
            let target = name.folding(options: .caseInsensitive, locale: nil)
            var found = false
            // Match by accessory name OR by outlet/service name (power strips expose each
            // outlet as a named service, e.g. "Bug Zapper", "TV, Stereo, Apple TV").
            for home in manager.homes {
                for acc in home.accessories {
                    let accMatch = acc.name.folding(options: .caseInsensitive, locale: nil) == target
                    for svc in acc.services {
                        let svcMatch = svc.name.folding(options: .caseInsensitive, locale: nil) == target
                        guard accMatch || svcMatch else { continue }
                        for c in svc.characteristics where c.characteristicType == HMCharacteristicTypePowerState {
                            found = true
                            c.writeValue(on) { error in
                                if let error = error {
                                    NSLog("[NovaHomeKit] power '\(name)'=\(on) failed: \(error.localizedDescription)")
                                } else {
                                    NSLog("[NovaHomeKit] set '\(name)' power=\(on)")
                                }
                            }
                        }
                    }
                }
            }
            return found ? json(200, ["status": "ok", "accessory": name, "on": on] as [String: Any])
                         : json(404, ["error": "no powerable accessory named: \(name)"] as [String: Any])

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
        let statusText = [200: "OK", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Unknown"
        return "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(ct); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private static func parseRequest(_ data: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let raw = String(data: data, encoding: .utf8), raw.contains("\r\n\r\n") else { return nil }
        let lines = raw.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let tokens = firstLine.components(separatedBy: " ")
        guard tokens.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<idx]).lowercased().trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        return (tokens[0], tokens[1], headers)
    }

    // MARK: - Authentication

    // Loopback is not an auth boundary — any web page the user visits can POST to
    // 127.0.0.1. Every request must carry the shared secret, and the Host header must
    // be a loopback name (DNS-rebinding guard). The token is provisioned out-of-band
    // (env var or installer-written file); if unset we fail closed.
    private static let expectedToken: String = {
        if let env = ProcessInfo.processInfo.environment["NOVAHOMEKIT_TOKEN"], !env.isEmpty {
            return env
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nova/novahomekit-token")
        if let t = try? String(contentsOf: url, encoding: .utf8) {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        NSLog("[NovaHomeKit] WARNING: no API token configured — all requests will be rejected")
        return ""
    }()

    private static func authorized(_ header: String?) -> Bool {
        guard !expectedToken.isEmpty else { return false }   // fail closed
        guard let header = header, header.hasPrefix("Bearer ") else { return false }
        let presented = Array(String(header.dropFirst("Bearer ".count)).utf8)
        let expected = Array(expectedToken.utf8)
        guard presented.count == expected.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<expected.count { diff |= presented[i] ^ expected[i] }
        return diff == 0
    }

    private static func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name == "127.0.0.1" || name == "localhost"
    }
}

// MARK: - App Entry Point

let server = HomeKitQueryServer.shared
server.start()
NSLog("[NovaHomeKit] Started — HomeKit initializing...")
RunLoop.main.run()
