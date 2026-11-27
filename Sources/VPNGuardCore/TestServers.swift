import Foundation

/// Public servers the Network Quality window can ping (and some can test speed with).
/// Checked on 2026-11-27: every host accepted a connection on port 443.
public enum TestProvider: String, Codable, CaseIterable, Sendable {
    case cloudflare, aws, gcp, digitalocean, vultr

    public var title: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .aws: return "AWS"
        case .gcp: return "Google Cloud"
        case .digitalocean: return "DigitalOcean"
        case .vultr: return "Vultr"
        }
    }
}

public struct TestServer: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// "aws:ap-southeast-1", "cloudflare:nearest".
    public var id: String
    public var provider: TestProvider
    /// For people: "Singapore", "Nearest".
    public var city: String
    /// The provider's own name for the place: "ap-southeast-1", "SGP1". Nil for Cloudflare and Vultr.
    public var code: String?
    /// What the ping connects to (port 443).
    public var host: String
    /// A file or endpoint to download for a speed test. Nil: ping only.
    public var downloadURL: String?
    /// An endpoint that takes a POST body for an upload test. Nil: no upload test.
    public var uploadURL: String?

    public var canTestSpeed: Bool { downloadURL != nil }
    public var title: String { "\(provider.title) · \(city)" }
    /// For a table cell: "Cloudflare", "Vultr Seoul".
    public var shortTitle: String { provider == .cloudflare ? provider.title : "\(provider.title) \(city)" }
    /// For a heading: "Cloudflare · nearest city", "AWS · Thailand".
    public var longTitle: String { provider == .cloudflare && city == "Nearest" ? "Cloudflare · nearest city" : title }

    /// "Ping", "Ping · speed ↓", "Ping · speed ↓↑".
    public var abilities: String {
        guard downloadURL != nil else { return "Ping" }
        return uploadURL != nil ? "Ping · speed ↓↑" : "Ping · speed ↓"
    }
}

public enum TestServers {
    public static let defaultID = "cloudflare:nearest"
    /// Cloudflare's public resolver: pinged with ICMP (falls back to port 443), as before servers
    /// could be chosen.
    public static let cloudflarePingAddress = "1.1.1.1"

    public static let cloudflare = TestServer(
        id: defaultID, provider: .cloudflare, city: "Nearest", code: nil, host: cloudflarePingAddress,
        downloadURL: "https://speed.cloudflare.com/__down?bytes=25000000",
        uploadURL: "https://speed.cloudflare.com/__up")

    public static let all: [TestServer] = [cloudflare] + aws + gcp + digitalOcean + vultr

    public static func server(id: String?) -> TestServer {
        all.first { $0.id == id } ?? cloudflare
    }

    /// Where speed tests go with this test server: the server itself if it has speed files, else Cloudflare.
    public static func speedServer(for s: TestServer) -> TestServer {
        s.canTestSpeed ? s : cloudflare
    }

    private static let aws: [TestServer] = ([
        ("ap-southeast-1", "Singapore"), ("ap-southeast-3", "Jakarta"), ("ap-southeast-5", "Malaysia"),
        ("ap-southeast-7", "Thailand"), ("ap-east-1", "Hong Kong"), ("ap-northeast-1", "Tokyo"),
        ("ap-northeast-2", "Seoul"), ("ap-south-1", "Mumbai"), ("ap-southeast-2", "Sydney"),
        ("eu-central-1", "Frankfurt"), ("eu-west-1", "Ireland"), ("eu-west-2", "London"),
        ("us-east-1", "N. Virginia"), ("us-west-1", "N. California"), ("us-west-2", "Oregon"),
        ("sa-east-1", "São Paulo"), ("ca-central-1", "Montreal"), ("me-central-1", "UAE"),
    ] as [(String, String)]).map { code, city in
        TestServer(id: "aws:\(code)", provider: .aws, city: city, code: code, host: "dynamodb.\(code).amazonaws.com")
    }

    private static let gcp: [TestServer] = ([
        ("asia-southeast1", "Singapore"), ("asia-southeast2", "Jakarta"), ("asia-east1", "Taiwan"),
        ("asia-east2", "Hong Kong"), ("asia-northeast1", "Tokyo"), ("asia-northeast3", "Seoul"),
        ("asia-south1", "Mumbai"), ("australia-southeast1", "Sydney"), ("europe-west1", "Belgium"),
        ("europe-west2", "London"), ("europe-west3", "Frankfurt"), ("europe-west4", "Netherlands"),
        ("us-central1", "Iowa"), ("us-east1", "South Carolina"), ("us-east4", "N. Virginia"),
        ("us-west1", "Oregon"), ("southamerica-east1", "São Paulo"), ("me-central2", "Dammam"),
    ] as [(String, String)]).map { code, city in
        TestServer(id: "gcp:\(code)", provider: .gcp, city: city, code: code, host: "storage.\(code).rep.googleapis.com")
    }

    private static let digitalOcean: [TestServer] = ([
        ("nyc3", "New York"), ("sfo2", "San Francisco"), ("sfo3", "San Francisco"), ("ams3", "Amsterdam"),
        ("fra1", "Frankfurt"), ("sgp1", "Singapore"), ("syd1", "Sydney"), ("blr1", "Bangalore"),
        ("lon1", "London"), ("tor1", "Toronto"), ("atl1", "Atlanta"),
    ] as [(String, String)]).map { code, city in
        TestServer(id: "digitalocean:\(code)", provider: .digitalocean, city: city, code: code.uppercased(),
                   host: "\(code).digitaloceanspaces.com")
    }

    private static let vultr: [TestServer] = ([
        ("fra-de", "Frankfurt"), ("ams-nl", "Amsterdam"), ("par-fr", "Paris"), ("lon-gb", "London"),
        ("mad-es", "Madrid"), ("waw-pl", "Warsaw"), ("sto-se", "Stockholm"), ("nj-us", "New Jersey"),
        ("il-us", "Chicago"), ("ga-us", "Atlanta"), ("fl-us", "Miami"), ("tx-us", "Dallas"),
        ("sjo-ca-us", "Silicon Valley"), ("lax-ca-us", "Los Angeles"), ("wa-us", "Seattle"),
        ("tor-ca", "Toronto"), ("mex-mx", "Mexico City"), ("sao-br", "São Paulo"), ("hnd-jp", "Tokyo"),
        ("osk-jp", "Osaka"), ("sel-kor", "Seoul"), ("sgp", "Singapore"), ("syd-au", "Sydney"),
        ("mel-au", "Melbourne"), ("bom-in", "Mumbai"), ("del-in", "Delhi"), ("blr-in", "Bangalore"),
        ("jnb-za", "Johannesburg"), ("tlv-il", "Tel Aviv"),
    ] as [(String, String)]).map { code, city in
        let host = "\(code)-ping.vultr.com"
        return TestServer(id: "vultr:\(code)", provider: .vultr, city: city, code: nil, host: host,
                          // The 1 GB file answers 503 to a plain download (checked 2026-11-27); the 100 MB one works.
                          downloadURL: "https://\(host)/vultr.com.100MB.bin")
    }
}
