import Foundation
import CoreWLAN
import CoreLocation
import AppKit

enum StoreWifi {
    private static var cachedAt = Date.distantPast
    private static var cachedName: String?

    static func payload(ssid: String, password: String) -> String? {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if pass.isEmpty {
            return "WIFI:S:\(escape(name));T:nopass;;"
        }
        return "WIFI:S:\(escape(name));T:WPA;P:\(escape(pass));;"
    }

    static func currentSSID() -> String? {
        if Date().timeIntervalSince(cachedAt) < 10 { return cachedName }
        let name = probe()
        cachedAt = Date()
        cachedName = name
        return name
    }

    static func fillCurrentSSID() async -> String? {
        cachedAt = .distantPast
        cachedName = nil
        if let name = probe() { return remember(name) }
        await WifiLocation.shared.ensure()
        cachedAt = .distantPast
        cachedName = nil
        return remember(probe())
    }

    private static func remember(_ name: String?) -> String? {
        cachedAt = Date()
        cachedName = name
        return name
    }

    private static func probe() -> String? {
        if let s = coreWLANSSID() { return s }
        let device = wifiDevice() ?? "en0"
        if let s = parseAirport(run("/usr/sbin/networksetup", ["-getairportnetwork", device])) { return s }
        if let s = parseSummary(run("/usr/sbin/ipconfig", ["getsummary", device])) { return s }
        return nil
    }

    private static func coreWLANSSID() -> String? {
        let name = CWWiFiClient.shared().interface()?.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return nil
    }

    private static func parseAirport(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.contains("not associated") || line.contains("没有") { return nil }
        guard let r = line.range(of: ": ") else { return nil }
        let name = String(line[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.contains("redacted") { return nil }
        return name
    }

    private static func parseSummary(_ raw: String?) -> String? {
        guard let raw else { return nil }
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.contains("SSID") , !t.contains("BSSID") else { continue }
            guard let r = t.range(of: ":") else { continue }
            let name = String(t[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.contains("redacted") || name.hasPrefix("<") { continue }
            return name
        }
        return nil
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\;,\":".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func wifiDevice() -> String? {
        guard let raw = run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
        let lines = raw.components(separatedBy: "\n")
        for i in 0..<lines.count {
            let line = lines[i]
            if line.contains("Wi-Fi") || line.contains("AirPort") || line.contains("Wi‑Fi") {
                if i + 1 < lines.count, lines[i + 1].contains("Device:") {
                    return lines[i + 1].replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    static func openLocationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}

final class WifiLocation: NSObject, CLLocationManagerDelegate {
    static let shared = WifiLocation()
    private let mgr = CLLocationManager()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        mgr.delegate = self
    }

    func ensure() async {
        let st = mgr.authorizationStatus
        if st == .authorizedAlways || st == .denied || st == .restricted {
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
            mgr.requestAlwaysAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.finish()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        finish()
    }

    private func finish() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
