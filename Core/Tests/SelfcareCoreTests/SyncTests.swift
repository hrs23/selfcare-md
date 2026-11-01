import Foundation
import Testing
@testable import SelfcareCore

final class MemoryProvider: SyncProvider, @unchecked Sendable {
    var files: [String: Data] = [:]

    func list() async throws -> [RemoteItem] {
        files.map { RemoteItem(path: $0.key, version: SyncHash.of($0.value)) }
    }

    func read(_ path: String) async throws -> Data {
        guard let d = files[path] else { throw SyncError.http(404, path) }
        return d
    }

    func write(_ path: String, _ data: Data) async throws -> String? {
        files[path] = data
        return SyncHash.of(data)
    }

    func delete(_ path: String) async throws {
        files[path] = nil
    }
}

func tempVault() -> Vault {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return Vault(root: url)
}

struct SyncTests {
    @Test func threeWay() async throws {
        let vault = tempVault()
        let remote = MemoryProvider()
        try vault.write("menus/A.md", "a")
        remote.files["menus/B.md"] = Data("b\n".utf8)
        remote.files["menus/C.md"] = Data("remote c\n".utf8)
        try vault.write("menus/C.md", "local c")
        let engine = SyncEngine(vault: vault, provider: remote, state: SyncState(), save: { _ in })
        let preview = try await engine.preview()
        #expect(preview.localCount == 2 && preview.remoteCount == 2 && preview.conflictCount == 1)
        try await engine.sync()
        #expect(remote.files["menus/A.md"] == Data("a\n".utf8))
        #expect(try vault.read("menus/B.md") == "b\n")
        #expect(engine.state.conflicts["menus/C.md"] != nil)
        #expect(try vault.read("menus/C.md") == "local c\n")

        try vault.delete("menus/A.md")
        remote.files["menus/B.md"] = Data("b2\n".utf8)
        try await engine.sync()
        #expect(remote.files["menus/A.md"] == nil)
        #expect(try vault.read("menus/B.md") == "b2\n")

        try vault.write("menus/B.md", "b3 local")
        remote.files["menus/B.md"] = Data("b3 remote\n".utf8)
        try await engine.sync()
        #expect(engine.state.conflicts["menus/B.md"] != nil)
        #expect(remote.files["menus/B.md"] == Data("b3 remote\n".utf8))

        try await engine.resolve("menus/B.md", with: .local)
        #expect(remote.files["menus/B.md"] == Data("b3 local\n".utf8))
        try await engine.resolve("menus/C.md", with: .remote)
        #expect(try vault.read("menus/C.md") == "remote c\n")
        #expect(engine.state.conflicts.isEmpty)
    }

    @Test func qr() {
        let json = #"{"type":"webdav","url":"https://dav.example.com/files/","username":"u","password":"p"}"#
        #expect(SyncConfig.fromQR(json) == .webdav(WebDAVConfig(url: "https://dav.example.com/files/", username: "u", password: "p")))
        let nc = "nc://login/user:alice&password:secret&server:https://cloud.example.com"
        #expect(SyncConfig.fromQR(nc) == .webdav(WebDAVConfig(url: "https://cloud.example.com/remote.php/dav/files/alice/", username: "alice", password: "secret")))
        let share = "https://cloud.example.com/index.php/s/AbCd123"
        #expect(SyncConfig.fromQR(share) == .webdav(WebDAVConfig(url: "https://cloud.example.com/public.php/webdav/", username: "AbCd123", password: "")))
        let s3 = #"{"type":"s3","endpoint":"https://x.r2.cloudflarestorage.com","region":"auto","bucket":"b","prefix":"vault","accessKey":"k","secret":"s"}"#
        #expect(SyncConfig.fromQR(s3) == .s3(S3Config(endpoint: "https://x.r2.cloudflarestorage.com", region: "auto", bucket: "b", prefix: "vault", accessKey: "k", secret: "s")))
    }

    @Test func sigv4() {
        let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
        let headers = S3Signer.sign(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/", query: "max-keys=2&prefix=J", payload: Data(), region: "us-east-1", accessKey: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", date: date)
        #expect(headers["Authorization"]?.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }

    @Test func multistatus() {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/vault/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/vault/menus/Squat%20A.md</d:href><d:propstat><d:prop><d:resourcetype/><d:getetag>"abc"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """
        let r = MultistatusParser(data: Data(xml.utf8)).parse()
        #expect(r.count == 2)
        #expect(r[0].collection && !r[1].collection)
        #expect(r[1].etag == "\"abc\"")
    }
}

struct PackAndToolTests {
    func importPack(_ name: String, image: UInt8) throws -> Pack {
        let data = Zip.write([
            ZipEntry(path: "\(name)/menus/Squat.md", data: Data("---\nrecord: sets\nfields: [reps]\n---\n\n![s](../media/s.png)\n".utf8)),
            ZipEntry(path: "\(name)/media/s.png", data: Data([image])),
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = try PackInstaller.importZip(data, suggestedName: "\(name).zip", into: dir)
        return Pack(id: name, name: name, root: root, isBundled: false, language: nil)
    }

    @Test func zipRoundTrip() throws {
        let entries = [ZipEntry(path: "Pack/menus/Squat.md", data: Data(String(repeating: "squat ", count: 100).utf8)), ZipEntry(path: "Pack/media/x.png", data: Data([0, 1, 2, 3]))]
        let data = Zip.write(entries)
        let read = try Zip.read(data)
        #expect(read == entries)
    }

    @Test func rejectsOversizedZip() throws {
        let data = Zip.write([ZipEntry(path: "a.bin", data: Data(count: 600)), ZipEntry(path: "b.bin", data: Data(count: 600))])
        #expect(throws: ZipError.tooLarge) { try Zip.read(data, maxEntrySize: 500, maxTotalSize: 2000) }
        #expect(throws: ZipError.tooLarge) { try Zip.read(data, maxEntrySize: 600, maxTotalSize: 1000) }
        #expect(try Zip.read(data, maxEntrySize: 600, maxTotalSize: 1200).count == 2)
    }

    @Test func rejectsUnsafeZip() {
        let data = Zip.write([ZipEntry(path: "../evil/menus/A.md", data: Data("x".utf8))])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: ZipError.self) { try PackInstaller.importZip(data, suggestedName: "evil.zip", into: dir) }
        #expect(throws: ZipError.self) { try PackInstaller.importZip(Data("not a zip".utf8), suggestedName: "x.zip", into: dir) }
    }

    @Test func importAndCopy() throws {
        let pack = try importPack("My Pack", image: 9)
        #expect(pack.root.lastPathComponent == "My Pack")
        #expect(pack.menuNames() == ["Squat"])
        let vault = tempVault()
        try PackInstaller.copy(menus: ["Squat"], from: pack, to: vault)
        #expect(vault.exists("menus/Squat.md"))
        #expect(try vault.readData("media/s.png") == Data([9]))
        let exported = try PackInstaller.export(name: "Out", menus: ["Squat"], vault: vault)
        #expect(try Zip.read(exported).map(\.path).sorted() == ["Out/media/s.png", "Out/menus/Squat.md"])
    }

    @Test func importNameNeverEscapesContainer() throws {
        let flat = Zip.write([ZipEntry(path: "menus/A.md", data: Data("---\nrecord: check\n---\n".utf8))])
        for suggested in ["...zip", "..zip", ".zip", ".x.zip"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let root = try PackInstaller.importZip(flat, suggestedName: suggested, into: dir)
            #expect(root.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
            #expect(!root.lastPathComponent.hasPrefix("."))
        }
        let nested = Zip.write([ZipEntry(path: ".P/menus/A.md", data: Data("---\nrecord: check\n---\n".utf8))])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = try PackInstaller.importZip(nested, suggestedName: "p.zip", into: dir)
        #expect(!root.lastPathComponent.hasPrefix("."))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("menus/A.md").path))
    }

    @Test func copyAndExportFollowOnlyImages() throws {
        let data = Zip.write([
            ZipEntry(path: "P/menus/A.md", data: Data("---\nrecord: check\n---\n\n![x](../daily/2026-01-01.md)\n".utf8)),
            ZipEntry(path: "P/daily/2026-01-01.md", data: Data("pack daily\n".utf8)),
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pack = Pack(id: "P", name: "P", root: try PackInstaller.importZip(data, suggestedName: "P.zip", into: dir), isBundled: false, language: nil)
        let vault = tempVault()
        try vault.write("daily/2026-01-01.md", "mine")
        try PackInstaller.copy(menus: ["A"], from: pack, to: vault, replacing: true)
        #expect(try vault.read("daily/2026-01-01.md") == "mine\n")
        let exported = try PackInstaller.export(name: "Out", menus: ["A"], vault: vault)
        #expect(try Zip.read(exported).map(\.path) == ["Out/menus/A.md"])
    }

    @Test func copyReplacesOnlyWhenAsked() throws {
        let pack = try importPack("P", image: 1)
        let vault = tempVault()
        try vault.write("menus/squat.md", "---\nrecord: check\n---\n")
        try vault.writeData("media/s.png", Data([7]))
        try PackInstaller.copy(menus: ["Squat"], from: pack, to: vault)
        #expect(try vault.read("menus/squat.md").contains("record: check"))
        #expect(try vault.readData("media/s.png") == Data([7]))
        try PackInstaller.copy(menus: ["Squat"], from: pack, to: vault, replacing: true)
        #expect(try vault.read("menus/squat.md").contains("record: sets"))
        #expect(!vault.exists("menus/Squat.md") || vault.menuNames().count == 1)
        #expect(try vault.readData("media/s.png") == Data([1]))
    }

    @Test func menuNamesSkipSymlinks() throws {
        let vault = tempVault()
        try vault.write("menus/Squat.md", "x")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).md")
        try Data("y".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: vault.root.appendingPathComponent("menus/Link.md"), withDestinationURL: outside)
        #expect(vault.menuNames() == ["Squat"])
        #expect(vault.list("menus", recursive: false) == ["menus/Squat.md"])
    }

    @Test func renameUpdatesLinks() throws {
        let vault = tempVault()
        try vault.write("menus/Squat.md", "---\nrecord: sets\nfields: [reps]\n---\n")
        try vault.write("daily/2026-09-27.md", "# 2026-09-27\n\n## Selfcare\n\n- [[squat]]\n  - [x] 10\n- [[Squatter]]\n")
        try vault.renameMenu(from: "Squat", to: "Back Squat")
        #expect(vault.exists("menus/Back Squat.md"))
        #expect(try vault.read("daily/2026-09-27.md").contains("- [[Back Squat]]\n  - [x] 10\n- [[Squatter]]"))
        #expect(throws: VaultError.self) { try vault.renameMenu(from: "Back Squat", to: "a/b") }
    }

    @Test func tools() async throws {
        let vault = tempVault()
        try vault.write("menus/Squat.md", "hello world")
        let tools = VaultTools(vault: vault)
        let ctx = ToolContext(imageGenerator: nil, fetcher: { _ in (Data(), nil) })
        let call = { (name: String, args: String) in ToolCall(id: "1", name: name, arguments: args) }
        guard case let .text(g) = try await tools.execute(call("glob", #"{"pattern":"menus/*.md"}"#), context: ctx) else { Issue.record(); return }
        #expect(g.hasPrefix("menus/Squat.md"))
        _ = try await tools.execute(call("edit", #"{"path":"menus/Squat.md","old_string":"world","new_string":"there"}"#), context: ctx)
        #expect(try vault.read("menus/Squat.md") == "hello there\n")
        await #expect(throws: VaultError.self) { try await tools.execute(call("read", #"{"path":"../etc/passwd"}"#), context: ctx) }
        await #expect(throws: VaultError.self) { try await tools.execute(call("write", #"{"path":"/etc/x","content":"x"}"#), context: ctx) }
        let perm = tools.permission(call("edit", #"{"path":"menus/Squat.md","old_string":"there","new_string":"you"}"#))
        #expect(perm.detail.contains("- hello there") && perm.detail.contains("+ hello you"))
    }

    @Test func globLimit() async throws {
        await #expect(processExitsWith: .success) {
            let vault = tempVault()
            try vault.write("menus/Squat.md", "x")
            let ctx = ToolContext(imageGenerator: nil, fetcher: { _ in (Data(), nil) })
            let result = try await VaultTools(vault: vault).execute(ToolCall(id: "1", name: "glob", arguments: #"{"pattern":"menus/*.md","limit":-1}"#), context: ctx)
            guard case .text = result else { exit(1) }
        }
        let vault = tempVault()
        try vault.write("menus/Squat.md", "x")
        let ctx = ToolContext(imageGenerator: nil, fetcher: { _ in (Data(), nil) })
        guard case let .text(t) = try await VaultTools(vault: vault).execute(ToolCall(id: "1", name: "glob", arguments: #"{"pattern":"menus/*.md","limit":0}"#), context: ctx) else { Issue.record(); return }
        #expect(t == "… 1 more")
    }

    @Test func glob() throws {
        let r = try Glob.regex("daily/2026-09-*.md")
        #expect(Glob.matches(r, "daily/2026-09-27.md"))
        #expect(!Glob.matches(r, "daily/2026-10-01.md"))
        let all = try Glob.regex("**/*.tcx")
        #expect(Glob.matches(all, "workouts/a.tcx") && Glob.matches(all, "a.tcx"))
        let braces = try Glob.regex("{a,b}.md,c")
        #expect(!Glob.matches(braces, "a.md.bak"))
        #expect(Glob.matches(braces, "a.md,c"))
        #expect(Glob.matches(try Glob.regex("x{a,b}"), "xa"))
    }

    @Test func modelChooser() {
        let models = ["gpt-5.6-luna", "gpt-6-luna", "gpt-6-luna-pro", "gpt-6-sol", "gpt-5.5-2026-04-23"]
        #expect(ModelChooser.pick(family: "luna", from: models, fallback: "x") == "gpt-6-luna")
        #expect(ModelChooser.pick(family: "luna", from: [], fallback: "x") == "x")
    }
}

struct WebDAVRequestTests {
    @Test func rootAndNestedPaths() throws {
        let p = try WebDAVProvider(config: WebDAVConfig(url: "https://dav.example.com/files/me", username: "u", password: "p"))
        #expect(p.request("", method: "PROPFIND", directory: true).url?.absoluteString == "https://dav.example.com/files/me/")
        #expect(p.request("menus/Back Squat.md", method: "GET").url?.absoluteString == "https://dav.example.com/files/me/menus/Back%20Squat.md")
        #expect(p.request("menus", method: "MKCOL", directory: true).url?.absoluteString == "https://dav.example.com/files/me/menus/")
        #expect(p.request("a:b.md", method: "GET").url?.absoluteString == "https://dav.example.com/files/me/a:b.md")
        #expect(p.request("c:d", method: "MKCOL", directory: true).url?.absoluteString == "https://dav.example.com/files/me/c:d/")
    }
}

struct S3RequestTests {
    @Test func invalidVirtualHostBucket() throws {
        for bucket in ["my bucket", "a/b", "a@b", "a:b"] {
            #expect(throws: SyncError.self) { try S3Provider(config: S3Config(endpoint: "", region: "eu-west-1", bucket: bucket, prefix: "", accessKey: "k", secret: "s")) }
        }
        let dotted = try S3Provider(config: S3Config(endpoint: "", region: "eu-west-1", bucket: "my.bucket", prefix: "", accessKey: "k", secret: "s"))
        #expect(try dotted.signedRequest(method: "GET", key: "a.md", query: []).url?.host == "my.bucket.s3.eu-west-1.amazonaws.com")
    }

    @Test func defaultRegion() throws {
        for region in ["", "auto"] {
            let p = try S3Provider(config: S3Config(endpoint: "", region: region, bucket: "b", prefix: "", accessKey: "k", secret: "s"))
            let r = try p.signedRequest(method: "GET", key: "a.md", query: [])
            #expect(r.url?.host == "b.s3.us-east-1.amazonaws.com")
            #expect(r.value(forHTTPHeaderField: "Authorization")?.contains("/us-east-1/s3/aws4_request") == true)
        }
        let r2 = try S3Provider(config: S3Config(endpoint: "https://x.r2.cloudflarestorage.com", region: "auto", bucket: "b", prefix: "", accessKey: "k", secret: "s"))
        #expect(try r2.signedRequest(method: "GET", key: "a.md", query: []).value(forHTTPHeaderField: "Authorization")?.contains("/auto/s3/aws4_request") == true)
    }
}

struct WebDAVIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SELFCARE_WEBDAV_URL"] != nil))
    func syncAgainstServer() async throws {
        let env = ProcessInfo.processInfo.environment
        let folder = "it-\(UUID().uuidString.prefix(8))"
        let root = try WebDAVProvider(config: WebDAVConfig(url: env["SELFCARE_WEBDAV_URL"]!, username: env["SELFCARE_WEBDAV_USER"] ?? "", password: env["SELFCARE_WEBDAV_PASSWORD"] ?? ""))
        try await root.testConnection()
        _ = try await root.write("\(folder)/.keep", Data())
        let provider = try WebDAVProvider(config: WebDAVConfig(url: env["SELFCARE_WEBDAV_URL"]! + folder + "/", username: env["SELFCARE_WEBDAV_USER"] ?? "", password: env["SELFCARE_WEBDAV_PASSWORD"] ?? ""))
        let a = tempVault()
        try a.write("menus/Back Squat.md", "---\nrecord: sets\nfields: [reps]\n---\n")
        try a.write("daily/2026-09-27.md", "# 2026-09-27\n\n## Selfcare\n\n- [[Back Squat]]\n  - [x] 10\n\n## Memo\n")
        let engineA = SyncEngine(vault: a, provider: provider, state: SyncState(), save: { _ in })
        try await engineA.sync()
        let b = tempVault()
        let engineB = SyncEngine(vault: b, provider: provider, state: SyncState(), save: { _ in })
        try await engineB.sync()
        #expect(try b.read("menus/Back Squat.md") == a.read("menus/Back Squat.md"))
        try await Task.sleep(for: .seconds(1.1))
        try b.write("daily/2026-09-27.md", "# 2026-09-27\n\n## Selfcare\n\n- [[Back Squat]]\n  - [x] 12\n\n## Memo\n")
        try await engineB.sync()
        try await engineA.sync()
        #expect(try a.read("daily/2026-09-27.md").contains("[x] 12"))
        try b.delete("menus/Back Squat.md")
        try await engineB.sync()
        try await engineA.sync()
        #expect(!a.exists("menus/Back Squat.md"))
        #expect(engineA.state.conflicts.isEmpty && engineB.state.conflicts.isEmpty)
    }
}
