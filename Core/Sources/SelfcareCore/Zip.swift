import Compression
import Foundation

public enum ZipError: Error, LocalizedError, Equatable {
    case broken
    case unsupported
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .broken: "The archive is broken"
        case .unsupported: "The archive uses an unsupported format"
        case let .unsafePath(p): "The archive has a path outside the pack: \(p)"
        }
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf {
                crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

enum RawDeflate {
    static func compress(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        let capacity = data.count + data.count / 2 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    static func decompress(_ data: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { return nil }
        return out
    }
}

public struct ZipEntry: Sendable, Hashable {
    public var path: String
    public var data: Data
    public var isDirectory: Bool { path.hasSuffix("/") }
}

public enum Zip {
    public static func read(_ data: Data) throws -> [ZipEntry] {
        let bytes = [UInt8](data)
        func u16(_ o: Int) throws -> Int {
            guard o + 2 <= bytes.count else { throw ZipError.broken }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int {
            guard o + 4 <= bytes.count else { throw ZipError.broken }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        guard bytes.count >= 22 else { throw ZipError.broken }
        var eocd = -1
        var i = bytes.count - 22
        let lower = max(0, bytes.count - 22 - 65535)
        while i >= lower {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.broken }
        let count = try u16(eocd + 10)
        var offset = try u32(eocd + 16)
        if count == 0xFFFF || offset == 0xFFFFFFFF { throw ZipError.unsupported }
        var entries: [ZipEntry] = []
        for _ in 0..<count {
            guard try u32(offset) == 0x02014B50 else { throw ZipError.broken }
            let flags = try u16(offset + 8)
            let method = try u16(offset + 10)
            let crc = UInt32(try u32(offset + 16))
            let compressedSize = try u32(offset + 20)
            let size = try u32(offset + 24)
            let nameLength = try u16(offset + 28)
            let extraLength = try u16(offset + 30)
            let commentLength = try u16(offset + 32)
            let local = try u32(offset + 42)
            guard offset + 46 + nameLength <= bytes.count else { throw ZipError.broken }
            let nameBytes = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            let name = (flags & 0x800) != 0 ? String(decoding: nameBytes, as: UTF8.self) : (String(bytes: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self))
            offset += 46 + nameLength + extraLength + commentLength
            if (flags & 1) != 0 { throw ZipError.unsupported }
            guard try u32(local) == 0x04034B50 else { throw ZipError.broken }
            let start = local + 30 + (try u16(local + 26)) + (try u16(local + 28))
            guard start + compressedSize <= bytes.count else { throw ZipError.broken }
            let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + compressedSize))
            let content: Data
            switch method {
            case 0: content = raw
            case 8:
                guard let d = RawDeflate.decompress(raw, size: size) else { throw ZipError.broken }
                content = d
            default: throw ZipError.unsupported
            }
            guard content.count == size, CRC32.checksum(content) == crc else { throw ZipError.broken }
            entries.append(ZipEntry(path: name.replacingOccurrences(of: "\\", with: "/"), data: content))
        }
        return entries
    }

    public static func write(_ entries: [ZipEntry]) -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ v: UInt32, _ d: inout Data) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            var method = 0
            var payload = entry.data
            if !entry.isDirectory, let c = RawDeflate.compress(entry.data), c.count < entry.data.count {
                method = 8
                payload = c
            }
            let localOffset = UInt32(out.count)
            var header = Data()
            le32(0x04034B50, &header)
            le16(20, &header)
            le16(0x800, &header)
            le16(method, &header)
            le16(0, &header)
            le16(0x21, &header)
            le32(crc, &header)
            le32(UInt32(payload.count), &header)
            le32(UInt32(entry.data.count), &header)
            le16(name.count, &header)
            le16(0, &header)
            out.append(header)
            out.append(name)
            out.append(payload)

            var c = Data()
            le32(0x02014B50, &c)
            le16(0x031E, &c)
            le16(20, &c)
            le16(0x800, &c)
            le16(method, &c)
            le16(0, &c)
            le16(0x21, &c)
            le32(crc, &c)
            le32(UInt32(payload.count), &c)
            le32(UInt32(entry.data.count), &c)
            le16(name.count, &c)
            le16(0, &c)
            le16(0, &c)
            le16(0, &c)
            le16(0, &c)
            le32(entry.isDirectory ? 0x41ED0010 : 0x81A40000, &c)
            le32(localOffset, &c)
            c.append(name)
            central.append(c)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        var end = Data()
        le32(0x06054B50, &end)
        le16(0, &end)
        le16(0, &end)
        le16(entries.count, &end)
        le16(entries.count, &end)
        le32(UInt32(central.count), &end)
        le32(centralOffset, &end)
        le16(0, &end)
        out.append(end)
        return out
    }

    public static func safePath(_ path: String) throws -> String {
        let p = path.replacingOccurrences(of: "\\", with: "/")
        if p.hasPrefix("/") || p.contains(":") && p.first != nil && p.dropFirst().first == ":" { throw ZipError.unsafePath(path) }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains(where: { $0 == ".." }) { throw ZipError.unsafePath(path) }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }
}
