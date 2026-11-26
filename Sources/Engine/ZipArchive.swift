import Foundation
import Compression

// Minimal ZIP reader/writer (no external dependencies, no Zip64).
// Reader keeps raw (still-compressed) bytes so untouched template entries
// are copied byte-for-byte, mirroring the original Python engine behaviour
// (entries kept as-is, only main.caml replaced, frames appended STORED).

enum ZipError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let m) = self { return m }; return nil }
}

struct ZipEntry {
    var name: String
    var flags: UInt16
    var method: UInt16
    var dosTime: UInt16
    var dosDate: UInt16
    var crc: UInt32
    var compSize: UInt32
    var size: UInt32
    var externalAttrs: UInt32
    var versionMadeBy: UInt16
    var dataOffset: Int
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    static func update(_ crc: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var c = ~crc
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
    static func of(_ bytes: [UInt8]) -> UInt32 { update(0, bytes) }
}

private func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
private func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
}

final class ZipReader {
    let bytes: [UInt8]
    private(set) var entries: [ZipEntry] = []

    init(url: URL) throws {
        bytes = [UInt8](try Data(contentsOf: url))
        try parse()
    }

    private func parse() throws {
        guard bytes.count >= 22 else { throw ZipError.invalid("Not a zip file") }
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65535)
        while i >= lowest {
            if u32(bytes, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalid("End of central directory not found") }
        let count = Int(u16(bytes, eocd + 10))
        var p = Int(u32(bytes, eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(bytes, p) == 0x02014b50 else {
                throw ZipError.invalid("Bad central directory")
            }
            let nameLen = Int(u16(bytes, p + 28)), extraLen = Int(u16(bytes, p + 30)), commentLen = Int(u16(bytes, p + 32))
            let local = Int(u32(bytes, p + 42))
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            guard local + 30 <= bytes.count, u32(bytes, local) == 0x04034b50 else {
                throw ZipError.invalid("Bad local header for \(name)")
            }
            let dataOffset = local + 30 + Int(u16(bytes, local + 26)) + Int(u16(bytes, local + 28))
            entries.append(ZipEntry(
                name: name, flags: u16(bytes, p + 8), method: u16(bytes, p + 10),
                dosTime: u16(bytes, p + 12), dosDate: u16(bytes, p + 14),
                crc: u32(bytes, p + 16), compSize: u32(bytes, p + 20), size: u32(bytes, p + 24),
                externalAttrs: u32(bytes, p + 38), versionMadeBy: u16(bytes, p + 4), dataOffset: dataOffset))
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    func rawBytes(_ e: ZipEntry) -> [UInt8] { Array(bytes[e.dataOffset..<(e.dataOffset + Int(e.compSize))]) }

    func data(_ e: ZipEntry) throws -> [UInt8] {
        let raw = rawBytes(e)
        if e.method == 0 { return raw }
        guard e.method == 8 else { throw ZipError.invalid("Unsupported method \(e.method)") }
        if e.size == 0 { return [] }
        var out = [UInt8](repeating: 0, count: Int(e.size))
        let n = compression_decode_buffer(&out, out.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        guard n == Int(e.size) else { throw ZipError.invalid("Inflate failed for \(e.name)") }
        return out
    }

    func entry(named n: String) -> ZipEntry? { entries.first { $0.name == n } }

    /// Equivalent of Python ZipFile.testzip(): returns first bad entry name or nil.
    func testZip() -> String? {
        for e in entries {
            guard let d = try? data(e), CRC32.of(d) == e.crc else { return e.name }
        }
        return nil
    }
}

final class ZipWriter {
    private let handle: FileHandle
    private var offset: UInt32 = 0
    private var central: [UInt8] = []
    private var count: UInt16 = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }

    /// Writes an entry whose payload is already in final (possibly compressed) form.
    func addRaw(name: String, flags: UInt16, method: UInt16, dosTime: UInt16, dosDate: UInt16,
                crc: UInt32, size: UInt32, payload: [UInt8], externalAttrs: UInt32, versionMadeBy: UInt16) {
        let nameBytes = Array(name.utf8)
        let f = flags & ~UInt16(8) // sizes are known: no data descriptor
        var h: [UInt8] = []
        h += le32(0x04034b50) + le16(20) + le16(f) + le16(method) + le16(dosTime) + le16(dosDate)
        h += le32(crc) + le32(UInt32(payload.count)) + le32(size) + le16(UInt16(nameBytes.count)) + le16(0) + nameBytes
        handle.write(Data(h)); handle.write(Data(payload))

        var c: [UInt8] = []
        c += le32(0x02014b50) + le16(versionMadeBy) + le16(20) + le16(f) + le16(method) + le16(dosTime) + le16(dosDate)
        c += le32(crc) + le32(UInt32(payload.count)) + le32(size) + le16(UInt16(nameBytes.count))
        c += le16(0) + le16(0) + le16(0) + le16(0) + le32(externalAttrs) + le32(offset) + nameBytes
        central += c
        offset += UInt32(h.count + payload.count)
        count += 1
    }

    func copy(_ e: ZipEntry, from r: ZipReader) {
        addRaw(name: e.name, flags: e.flags, method: e.method, dosTime: e.dosTime, dosDate: e.dosDate,
               crc: e.crc, size: e.size, payload: r.rawBytes(e), externalAttrs: e.externalAttrs, versionMadeBy: e.versionMadeBy)
    }

    /// Replaces content of an existing entry, keeping its metadata; deflates when it helps.
    func replace(_ e: ZipEntry, with data: [UInt8]) {
        var method: UInt16 = 0
        var payload = data
        if e.method == 8, !data.isEmpty {
            var buf = [UInt8](repeating: 0, count: data.count + 1024)
            let n = compression_encode_buffer(&buf, buf.count, data, data.count, nil, COMPRESSION_ZLIB)
            if n > 0 && n < data.count { method = 8; payload = Array(buf[0..<n]) }
        }
        addRaw(name: e.name, flags: e.flags, method: method, dosTime: e.dosTime, dosDate: e.dosDate,
               crc: CRC32.of(data), size: UInt32(data.count), payload: payload,
               externalAttrs: e.externalAttrs, versionMadeBy: e.versionMadeBy)
    }

    /// STORED entry stamped 1980-01-01 00:00 like Python's ZipInfo(name) default.
    func addStored(name: String, data: [UInt8]) {
        addRaw(name: name, flags: 0, method: 0, dosTime: 0, dosDate: 33, crc: CRC32.of(data),
               size: UInt32(data.count), payload: data, externalAttrs: 0o600 << 16, versionMadeBy: 20)
    }

    func finish() {
        let cdOffset = offset
        handle.write(Data(central))
        var e: [UInt8] = []
        e += le32(0x06054b50) + le16(0) + le16(0) + le16(count) + le16(count)
        e += le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        handle.write(Data(e))
        handle.closeFile()
    }
}
