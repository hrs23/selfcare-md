import CryptoKit
import Foundation

public enum SyncError: Error, LocalizedError, Equatable {
    case http(Int, String)
    case invalidConfig(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case let .http(code, path):
            switch code {
            case 401, 403: "Authentication failed (\(code))"
            case 404: "Not found: \(path)"
            default: "Server error \(code): \(path)"
            }
        case let .invalidConfig(m): m
        case .badResponse: "Unexpected server response"
        }
    }
}

public struct WebDAVConfig: Codable, Sendable, Hashable {
    public var url: String
    public var username: String
    public var password: String

    public init(url: String, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }
}

public struct S3Config: Codable, Sendable, Hashable {
    public var endpoint: String
    public var region: String
    public var bucket: String
    public var prefix: String
    public var accessKey: String
    public var secret: String

    public init(endpoint: String, region: String, bucket: String, prefix: String, accessKey: String, secret: String) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.accessKey = accessKey
        self.secret = secret
    }
}

public enum SyncConfig: Codable, Sendable, Hashable {
    case webdav(WebDAVConfig)
    case s3(S3Config)

    public var label: String {
        switch self {
        case let .webdav(c): URL(string: c.url)?.host ?? c.url
        case let .s3(c): "\(c.bucket)" + (c.prefix.isEmpty ? "" : "/\(c.prefix)")
        }
    }

    public var kindLabel: String {
        switch self {
        case .webdav: "WebDAV"
        case .s3: "S3"
        }
    }

    public static func fromQR(_ text: String) -> SyncConfig? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let s: (String...) -> String = { keys in
                for k in keys { if let v = obj[k] as? String { return v } }
                return ""
            }
            switch (obj["type"] as? String)?.lowercased() {
            case "webdav":
                let url = s("url")
                guard !url.isEmpty else { return nil }
                return .webdav(WebDAVConfig(url: url, username: s("username", "user"), password: s("password")))
            case "s3":
                let bucket = s("bucket")
                guard !bucket.isEmpty else { return nil }
                return .s3(S3Config(endpoint: s("endpoint", "url"), region: s("region").isEmpty ? "auto" : s("region"), bucket: bucket, prefix: s("prefix"), accessKey: s("accessKey", "accessKeyId", "access_key_id"), secret: s("secret", "secretAccessKey", "secret_access_key")))
            default:
                return nil
            }
        }
        if trimmed.hasPrefix("nc://login/") {
            let rest = trimmed.dropFirst("nc://login/".count)
            var user = ""
            var password = ""
            var server = ""
            for part in rest.split(separator: "&") {
                let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let value = kv[1].removingPercentEncoding ?? kv[1]
                switch kv[0] {
                case "user": user = value
                case "password": password = value
                case "server": server = value
                default: break
                }
            }
            guard !user.isEmpty, !server.isEmpty else { return nil }
            let base = server.hasSuffix("/") ? String(server.dropLast()) : server
            let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
            return .webdav(WebDAVConfig(url: "\(base)/remote.php/dav/files/\(encodedUser)/", username: user, password: password))
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, scheme.hasPrefix("http") {
            let comps = url.path.split(separator: "/")
            if let sIndex = comps.firstIndex(of: "s"), sIndex + 1 < comps.count {
                let token = String(comps[sIndex + 1])
                let prefixPath = comps[..<sIndex].filter { $0 != "index.php" }.joined(separator: "/")
                var base = "\(scheme)://\(url.host ?? "")"
                if let port = url.port { base += ":\(port)" }
                if !prefixPath.isEmpty { base += "/" + prefixPath }
                return .webdav(WebDAVConfig(url: "\(base)/public.php/webdav/", username: token, password: ""))
            }
        }
        return nil
    }
}

struct HTTP {
    let session: URLSession

    static let uncached: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.badResponse }
        return (data, http)
    }
}

public final class WebDAVProvider: SyncProvider, @unchecked Sendable {
    public let config: WebDAVConfig
    let base: URL
    let http = HTTP(session: HTTP.uncached)
    private var createdDirs = Set<String>()
    private let lock = NSLock()

    public init(config: WebDAVConfig) throws {
        var url = config.url.trimmingCharacters(in: .whitespaces)
        if !url.hasSuffix("/") { url += "/" }
        guard let u = URL(string: url), u.scheme?.hasPrefix("http") == true else { throw SyncError.invalidConfig("Invalid URL") }
        self.config = config
        self.base = u
    }

    func request(_ path: String, method: String, directory: Bool = false) -> URLRequest {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))) ?? String($0) }.joined(separator: "/")
        let relative = encoded + (directory && !encoded.isEmpty ? "/" : "")
        let url = relative.isEmpty ? base : (URL(string: relative, relativeTo: base)?.absoluteURL ?? base.appendingPathComponent(path))
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 60
        if !config.username.isEmpty || !config.password.isEmpty {
            let token = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
            r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    struct Resource {
        var path: String
        var isCollection: Bool
        var etag: String?
        var modified: String?
        var length: String?
    }

    func propfind(_ path: String, depth: String) async throws -> [Resource] {
        var r = request(path, method: "PROPFIND", directory: true)
        r.setValue(depth, forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)
        let (data, response) = try await http.send(r)
        guard response.statusCode == 207 else { throw SyncError.http(response.statusCode, path.isEmpty ? "/" : path) }
        let parser = MultistatusParser(data: data)
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return parser.parse().compactMap { res in
            var href = res.href
            if let u = URL(string: href), u.host != nil { href = u.path }
            href = href.removingPercentEncoding ?? href
            let decodedBase = basePath.removingPercentEncoding ?? basePath
            guard href.hasPrefix(decodedBase) || href + "/" == decodedBase else { return nil }
            var rel = href.count >= decodedBase.count ? String(href.dropFirst(decodedBase.count)) : ""
            if rel.hasSuffix("/") { rel.removeLast() }
            return Resource(path: rel, isCollection: res.collection, etag: res.etag, modified: res.modified, length: res.length)
        }
    }

    public func testConnection() async throws {
        _ = try await propfind("", depth: "0")
    }

    public func folders(at path: String) async throws -> [String] {
        try await propfind(path, depth: "1").filter { $0.isCollection && $0.path != path && !$0.path.isEmpty }.map(\.path).sorted()
    }

    public func list() async throws -> [RemoteItem] {
        var result: [RemoteItem] = []
        var queue = [""]
        var visited = Set<String>()
        while let dir = queue.popLast() {
            if visited.contains(dir) { continue }
            visited.insert(dir)
            for res in try await propfind(dir, depth: "1") where res.path != dir {
                if res.isCollection {
                    queue.append(res.path)
                } else {
                    let version = res.etag ?? "\(res.modified ?? "")|\(res.length ?? "")"
                    result.append(RemoteItem(path: res.path, version: version))
                }
            }
        }
        return result
    }

    public func read(_ path: String) async throws -> Data {
        let (data, response) = try await http.send(request(path, method: "GET"))
        guard (200..<300).contains(response.statusCode) else { throw SyncError.http(response.statusCode, path) }
        return data
    }

    public func write(_ path: String, _ data: Data) async throws -> String? {
        let parts = path.split(separator: "/").dropLast()
        var current = ""
        for part in parts {
            current = current.isEmpty ? String(part) : current + "/" + part
            let known = lock.withLock { createdDirs.contains(current) }
            if known { continue }
            let (_, response) = try await http.send(request(current, method: "MKCOL", directory: true))
            guard [201, 405, 301, 200].contains(response.statusCode) else { throw SyncError.http(response.statusCode, current) }
            let dir = current
            lock.withLock { _ = createdDirs.insert(dir) }
        }
        var r = request(path, method: "PUT")
        r.httpBody = data
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await http.send(r)
        guard (200..<300).contains(response.statusCode) else { throw SyncError.http(response.statusCode, path) }
        return response.value(forHTTPHeaderField: "ETag")
    }

    public func delete(_ path: String) async throws {
        let (_, response) = try await http.send(request(path, method: "DELETE"))
        guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else { throw SyncError.http(response.statusCode, path) }
    }
}

final class MultistatusParser: NSObject, XMLParserDelegate {
    struct Response {
        var href = ""
        var collection = false
        var etag: String?
        var modified: String?
        var length: String?
        var ok = true
    }

    let data: Data
    var responses: [Response] = []
    var current: Response?
    var text = ""
    var inPropstat = false
    var propstatOK = true
    var pending = Response()

    init(data: Data) {
        self.data = data
    }

    func parse() -> [Response] {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = self
        p.parse()
        return responses
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response": current = Response()
        case "propstat":
            inPropstat = true
            propstatOK = true
            pending = Response()
        case "collection": pending.collection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href":
            if !inPropstat { current?.href = value }
        case "getetag": pending.etag = value.isEmpty ? nil : value
        case "getlastmodified": pending.modified = value.isEmpty ? nil : value
        case "getcontentlength": pending.length = value.isEmpty ? nil : value
        case "status":
            if inPropstat { propstatOK = value.contains(" 200") }
        case "propstat":
            inPropstat = false
            if propstatOK {
                if pending.collection { current?.collection = true }
                if let e = pending.etag { current?.etag = e }
                if let m = pending.modified { current?.modified = m }
                if let l = pending.length { current?.length = l }
            }
        case "response":
            if let c = current { responses.append(c) }
            current = nil
        default: break
        }
        text = ""
    }
}

public final class S3Provider: SyncProvider, @unchecked Sendable {
    public let config: S3Config
    let http = HTTP(session: HTTP.uncached)
    let endpoint: URL
    let virtualHost: Bool

    public init(config: S3Config) throws {
        var e = config.endpoint.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { e = "https://s3.\(config.region.isEmpty ? "us-east-1" : config.region).amazonaws.com" }
        if !e.contains("://") { e = "https://" + e }
        while e.hasSuffix("/") { e.removeLast() }
        guard let u = URL(string: e), u.host != nil else { throw SyncError.invalidConfig("Invalid endpoint") }
        guard !config.bucket.isEmpty else { throw SyncError.invalidConfig("Bucket is empty") }
        self.config = config
        self.endpoint = u
        self.virtualHost = u.host!.hasSuffix("amazonaws.com")
    }

    var keyPrefix: String {
        let p = config.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return p.isEmpty ? "" : p + "/"
    }

    static func encode(_ s: String, slash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if slash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func signedRequest(method: String, key: String?, query: [(String, String)], body: Data = Data(), date: Date = Date()) -> URLRequest {
        let host: String
        var path: String
        if virtualHost {
            host = "\(config.bucket).\(endpoint.host!)"
            path = "/" + (key.map { Self.encode($0, slash: true) } ?? "")
        } else {
            host = endpoint.host! + (endpoint.port.map { ":\($0)" } ?? "")
            let basePath = endpoint.path.isEmpty ? "" : endpoint.path
            path = basePath + "/" + Self.encode(config.bucket, slash: false) + (key.map { "/" + Self.encode($0, slash: true) } ?? "")
        }
        let encoded: [(String, String)] = query.map { pair in (Self.encode(pair.0, slash: false), Self.encode(pair.1, slash: false)) }
        let sortedPairs = encoded.sorted { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        let canonicalQuery = sortedPairs.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
        let scheme = endpoint.scheme ?? "https"
        var comps = scheme + "://" + host + path
        if !canonicalQuery.isEmpty { comps += "?" + canonicalQuery }
        var r = URLRequest(url: URL(string: comps)!)
        r.httpMethod = method
        r.timeoutInterval = 60
        if !body.isEmpty || method == "PUT" { r.httpBody = body }
        let signed = S3Signer.sign(method: method, host: host, path: path, query: canonicalQuery, payload: body, region: config.region.isEmpty ? "us-east-1" : config.region, accessKey: config.accessKey, secret: config.secret, date: date)
        for (k, v) in signed { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    public func testConnection() async throws {
        let r = signedRequest(method: "GET", key: nil, query: [("list-type", "2"), ("max-keys", "1"), ("prefix", keyPrefix)])
        let (_, response) = try await http.send(r)
        guard (200..<300).contains(response.statusCode) else { throw SyncError.http(response.statusCode, config.bucket) }
    }

    public func list() async throws -> [RemoteItem] {
        var result: [RemoteItem] = []
        var token: String?
        repeat {
            var q = [("list-type", "2"), ("prefix", keyPrefix)]
            if let token { q.append(("continuation-token", token)) }
            let (data, response) = try await http.send(signedRequest(method: "GET", key: nil, query: q))
            guard (200..<300).contains(response.statusCode) else { throw SyncError.http(response.statusCode, config.bucket) }
            let parsed = S3ListParser(data: data).parse()
            for item in parsed.items where item.key.hasPrefix(keyPrefix) && !item.key.hasSuffix("/") {
                result.append(RemoteItem(path: String(item.key.dropFirst(keyPrefix.count)), version: item.etag))
            }
            token = parsed.truncated ? parsed.next : nil
        } while token != nil
        return result
    }

    public func read(_ path: String) async throws -> Data {
        let (data, response) = try await http.send(signedRequest(method: "GET", key: keyPrefix + path, query: []))
        guard (200..<300).contains(response.statusCode) else { throw SyncError.http(response.statusCode, path) }
        return data
    }

    public func write(_ path: String, _ data: Data) async throws -> String? {
        let (_, response) = try await http.send(signedRequest(method: "PUT", key: keyPrefix + path, query: [], body: data))
        guard (200..<300).contains(response.statusCode) else { throw SyncError.http(response.statusCode, path) }
        return response.value(forHTTPHeaderField: "ETag")
    }

    public func delete(_ path: String) async throws {
        let (_, response) = try await http.send(signedRequest(method: "DELETE", key: keyPrefix + path, query: []))
        guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else { throw SyncError.http(response.statusCode, path) }
    }
}

public enum S3Signer {
    static func hex(_ data: some Sequence<UInt8>) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func sign(method: String, host: String, path: String, query: String, payload: Data, region: String, accessKey: String, secret: String, date: Date) -> [String: String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = f.string(from: date)
        let day = String(amzDate.prefix(8))
        let payloadHash = hex(SHA256.hash(data: payload))
        let headers = [("host", host), ("x-amz-content-sha256", payloadHash), ("x-amz-date", amzDate)]
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonical = [method, path.isEmpty ? "/" : path, query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let kDate = hmac(Data("AWS4\(secret)".utf8), day)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, "s3")
        let kSigning = hmac(kService, "aws4_request")
        let signature = hex(hmac(kSigning, toSign))
        return [
            "x-amz-date": amzDate,
            "x-amz-content-sha256": payloadHash,
            "Authorization": "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
        ]
    }
}

final class S3ListParser: NSObject, XMLParserDelegate {
    struct Item {
        var key = ""
        var etag = ""
    }

    let data: Data
    var items: [Item] = []
    var current: Item?
    var text = ""
    var truncated = false
    var next: String?

    init(data: Data) {
        self.data = data
    }

    func parse() -> (items: [Item], truncated: Bool, next: String?) {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return (items, truncated, next)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "Contents" { current = Item() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "Key": current?.key = text
        case "ETag": current?.etag = text
        case "Contents":
            if let c = current { items.append(c) }
            current = nil
        case "IsTruncated": truncated = text == "true"
        case "NextContinuationToken": next = text
        default: break
        }
        text = ""
    }
}
