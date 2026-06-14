import AppKit
import Foundation

public enum LookupProviderCategory: String, CaseIterable, Identifiable, Sendable {
    case geoIP = "GeoIP"
    case bgp = "BGP"
    case whois = "WHOIS"
    case abuse = "Abuse"
    case reputation = "Reputation"
    case malware = "Malware"

    public var id: String { rawValue }
}

public struct LookupProvider: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var category: LookupProviderCategory
    public var urlTemplate: String
    public var isEnabled: Bool
    public var requiresAccount: Bool
    public var notes: String

    public static let presets: [LookupProvider] = [
        LookupProvider(id: "ipinfo", name: "ipinfo.io", category: .geoIP, urlTemplate: "https://ipinfo.io/{ip}", isEnabled: true, requiresAccount: false, notes: "General GeoIP and ASN view."),
        LookupProvider(id: "he-bgp", name: "Hurricane Electric BGP", category: .bgp, urlTemplate: "https://bgp.he.net/ip/{ip}", isEnabled: true, requiresAccount: false, notes: "BGP prefix and ASN context."),
        LookupProvider(id: "abuseipdb", name: "AbuseIPDB", category: .abuse, urlTemplate: "https://www.abuseipdb.com/check/{ip}", isEnabled: true, requiresAccount: false, notes: "Abuse reports; some features may require an account."),
        LookupProvider(id: "iplocation", name: "IP Location", category: .geoIP, urlTemplate: "https://www.iplocation.net/ip-lookup/{ip}", isEnabled: true, requiresAccount: false, notes: "Multi-source approximate geolocation."),
        LookupProvider(id: "ip2location", name: "IP2Location Demo", category: .geoIP, urlTemplate: "https://www.ip2location.com/demo/{ip}", isEnabled: true, requiresAccount: false, notes: "Demo lookup page."),
        LookupProvider(id: "domaintools", name: "DomainTools WHOIS", category: .whois, urlTemplate: "https://whois.domaintools.com/{ip}", isEnabled: true, requiresAccount: false, notes: "WHOIS-style page; some features may require account access."),
        LookupProvider(id: "talos", name: "Cisco Talos", category: .reputation, urlTemplate: "https://talosintelligence.com/reputation_center/lookup?search={ip}", isEnabled: true, requiresAccount: false, notes: "Cisco Talos reputation center."),
        LookupProvider(id: "virustotal", name: "VirusTotal", category: .malware, urlTemplate: "https://www.virustotal.com/gui/ip-address/{ip}", isEnabled: true, requiresAccount: false, notes: "Malware/reputation page; account may be useful.")
    ]
}

public enum LookupError: LocalizedError {
    case noRemoteIP
    case reservedAddress
    case unknownProvider
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .noRemoteIP: "No remote IP is available for the selected connection."
        case .reservedAddress: "This address is local/reserved and cannot be meaningfully geolocated."
        case .unknownProvider: "The selected lookup provider is unavailable."
        case .invalidURL: "The lookup provider URL could not be created."
        }
    }
}

public struct LookupService: Sendable {
    private let validator = IPAddressValidator()

    public init() {}

    public func canLookup(ip: String?) -> Result<String, LookupError> {
        guard let ip, !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.noRemoteIP)
        }
        let normalized = validator.normalize(ip)
        switch validator.validate(normalized) {
        case .valid:
            return .success(normalized)
        case .warning, .refused:
            return .failure(.reservedAddress)
        }
    }

    @MainActor
    public func open(ip: String, providerID: String) throws {
        guard let provider = LookupProvider.presets.first(where: { $0.id == providerID && $0.isEnabled }) else {
            throw LookupError.unknownProvider
        }
        guard let encoded = ip.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw LookupError.invalidURL
        }
        let rawURL = provider.urlTemplate.replacingOccurrences(of: "{ip}", with: encoded)
        guard let url = URL(string: rawURL) else {
            throw LookupError.invalidURL
        }
        NSWorkspace.shared.open(url)
    }
}
