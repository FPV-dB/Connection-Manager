import Foundation

public struct GoogleIPRangeResult: Sendable {
    public let ranges: [String]
    public let fetchedAt: Date
}

public enum GoogleIPRangeError: LocalizedError {
    case invalidResponse(URL)
    case noRanges

    public var errorDescription: String? {
        switch self {
        case let .invalidResponse(url):
            return "Google returned an invalid IP range response from \(url.absoluteString)."
        case .noRanges:
            return "Google's published feeds did not contain any IP ranges."
        }
    }
}

public struct GoogleIPRangeService: Sendable {
    public static let managedBlocklistName = "Known Google IP Ranges"
    public static let googleServicesURL = URL(string: "https://www.gstatic.com/ipranges/goog.json")!
    public static let googleCloudURL = URL(string: "https://www.gstatic.com/ipranges/cloud.json")!

    public init() {}

    public func fetchAllKnownRanges() async throws -> GoogleIPRangeResult {
        async let servicesData = fetch(Self.googleServicesURL)
        async let cloudData = fetch(Self.googleCloudURL)
        let ranges = Set(try parse(data: await servicesData) + parse(data: await cloudData))
        guard !ranges.isEmpty else { throw GoogleIPRangeError.noRanges }
        return GoogleIPRangeResult(ranges: ranges.sorted(), fetchedAt: Date())
    }

    public func parse(data: Data) throws -> [String] {
        let document = try JSONDecoder().decode(RangeDocument.self, from: data)
        return document.prefixes.compactMap { $0.ipv4Prefix ?? $0.ipv6Prefix }
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw GoogleIPRangeError.invalidResponse(url)
        }
        return data
    }
}

private struct RangeDocument: Decodable {
    let prefixes: [RangePrefix]
}

private struct RangePrefix: Decodable {
    let ipv4Prefix: String?
    let ipv6Prefix: String?
}
