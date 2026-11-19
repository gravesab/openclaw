import Foundation
import Network

/// One ranch server reachable two ways: its LAN address on the ranch Wi-Fi, and its
/// Tailscale address from anywhere. On Wi-Fi or Ethernet the LAN address is tried
/// first; when it does not answer, or there is no local network, Tailscale is used.
/// Kept identical in PropertyManager (apps/propertymanager-ios), RanchOS, and Livestock.
struct ServerRoute: Hashable, Sendable {
    let lan: URL?
    let tailscale: URL

    /// A single address the user entered: used as-is on every network.
    static func fixed(_ url: URL) -> ServerRoute {
        ServerRoute(lan: nil, tailscale: url)
    }

    func candidates(onLocalNetwork: Bool) -> [Candidate] {
        guard onLocalNetwork, let lan, lan != tailscale else { return [Candidate(url: tailscale, via: .tailscale)] }
        return [Candidate(url: lan, via: .lan), Candidate(url: tailscale, via: .tailscale)]
    }

    struct Candidate: Hashable, Sendable {
        let url: URL
        let via: ServerRouteVia
    }
}

enum ServerRouteVia: String, Sendable {
    case lan
    case tailscale

    var label: String {
        switch self {
        case .lan: "Ranch Wi-Fi"
        case .tailscale: "Tailscale"
        }
    }
}

/// Picks the first address of a route that answers, and remembers it until the
/// network changes or a request fails.
actor ServerRouteResolver {
    /// True when the server answered at all. Any HTTP status counts: 401 still proves the route works.
    typealias Probe = @Sendable (URL) async -> Bool

    private let probe: Probe
    private var chosen: [ServerRoute: ServerRoute.Candidate] = [:]

    init(probe: @escaping Probe = ServerRouteResolver.httpProbe) {
        self.probe = probe
    }

    /// When nothing answers, the Tailscale address is returned so the error the user
    /// sees comes from the address that should work anywhere.
    func resolve(_ route: ServerRoute, onLocalNetwork: Bool) async -> ServerRoute.Candidate {
        let candidates = route.candidates(onLocalNetwork: onLocalNetwork)
        if let cached = chosen[route], candidates.contains(cached) { return cached }
        for candidate in candidates where await probe(candidate.url) {
            chosen[route] = candidate
            return candidate
        }
        chosen[route] = nil
        return candidates.last ?? ServerRoute.Candidate(url: route.tailscale, via: .tailscale)
    }

    func forgetChoices() {
        chosen.removeAll()
    }

    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Short enough that a dead LAN address does not hold up a switch to Tailscale.
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static let httpProbe: Probe = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await probeSession.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    /// Errors raised before a request could reach any server, so resending it cannot
    /// apply a write twice. Timeouts and dropped connections are excluded: the server
    /// may already have handled the request.
    static func neverReachedServer(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Errors that mean "this address is unreachable", as opposed to a server answer.
    static func isUnreachable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}

/// Reports whether the device is on Wi-Fi or Ethernet, and calls back when that or
/// reachability changes so routes can be re-chosen.
@MainActor
final class NetworkPathWatcher {
    /// Off until the monitor reports, so a cold start on cellular does not probe the LAN.
    private(set) var onLocalNetwork = false
    private(set) var hasReportedPath = false
    private let monitor = NWPathMonitor()
    private var lastSignature: String?

    init(onChange: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let local = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            let signature = "\(path.status)-\(local)-\(path.availableInterfaces.map(\.name).sorted())"
            Task { @MainActor in
                guard let self else { return }
                self.onLocalNetwork = local
                self.hasReportedPath = true
                // The first update only reports the starting state.
                let changed = self.lastSignature != nil && self.lastSignature != signature
                self.lastSignature = signature
                if changed { onChange() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ServerRoute.NetworkPathWatcher"))
    }

    /// Waits briefly for the monitor's first report; NWPathMonitor usually answers at once.
    func waitForFirstPath(timeout: Duration = .milliseconds(500)) async {
        let deadline = ContinuousClock.now + timeout
        while !hasReportedPath, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    deinit {
        monitor.cancel()
    }
}
