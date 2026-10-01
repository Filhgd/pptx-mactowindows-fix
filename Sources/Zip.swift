import Foundation
import Compression

/// Minimal ZIP reader/writer, enough for Office files (.pptx).
/// Unchanged entries are copied byte for byte; only new or changed entries are recompressed.

enum ZipError: Error, CustomStringConvertible {
    case notZip
    case unsupported(String)
    case corrupt(String)

    var description: String {
        switch self {
        case .notZip: return "This is not a valid PowerPoint file (.pptx)."
        case .unsupported(let s): return "Not supported: \(s)"
        case .corrupt(let s): return "Damaged file: \(s)"
        }
    }
}

struct ZipEntry {
    var name: String
    var method: UInt16          // 0 = stored, 8 = deflate
    var flags: UInt16
    var modTime: UInt16
    var modDate: UInt16
    var crc32: UInt32
    var uncompressedSize: Int
    var externalAttributes: UInt32
    var rawData: [UInt8]        // data exactly as stored in the archive

    func contents() throws -> [UInt8] {
        switch method {
        case 0:
            return rawData
        case 8:
            return try Deflate.inflate(rawData, expectedSize: uncompressedSize, name: name)
        default:
            throw ZipError.unsupported("compression method \(method) in \(name)")
        }
    }

    /// New entry with the given contents. Deflates unless that does not help.
    static func make(name: String, contents: [UInt8], like template: ZipEntry? = nil) -> ZipEntry {
        let crc = CRC32.checksum(contents)
        var method: UInt16 = 0
        var raw = contents
        if let deflated = Deflate.deflate(contents), deflated.count < contents.count {
            method = 8
            raw = deflated
        }
        let (t, d) = template.map { ($0.modTime, $0.modDate) } ?? DosTime.now()
        return ZipEntry(name: name, method: method, flags: 0,
                        modTime: t, modDate: d, crc32: crc, uncompressedSize: contents.count,
                        externalAttributes: template?.externalAttributes ?? 0, rawData: raw)
    }
}

enum ZipArchive {
    /// Limits against zip bombs: real presentations stay far below these.
    static let maxPartSize = 1 << 30        // uncompressed size of one part
    static let maxTotalSize = 4 << 30       // uncompressed size of all parts together

    static func read(_ bytes: [UInt8]) throws -> [ZipEntry] {
        let n = bytes.count
        guard n >= 22 else { throw ZipError.notZip }
        // End of central directory record, searched from the end.
        var eocd = -1
        var i = n - 22
        let lowest = max(0, n - 22 - 65535)
        while i >= lowest {
            if bytes.u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = Int(bytes.u16(eocd + 10))
        let cdOffset = Int(bytes.u32(eocd + 16))
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            throw ZipError.unsupported("ZIP64 files (larger than 4 GB)")
        }

        var entries: [ZipEntry] = []
        var spans: [Range<Int>] = []        // local header + data of each entry
        var dataRanges: [Range<Int>] = []
        var total = 0
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= n, bytes.u32(p) == 0x02014b50 else { throw ZipError.corrupt("central directory") }
            let flags = bytes.u16(p + 8)
            let method = bytes.u16(p + 10)
            let time = bytes.u16(p + 12)
            let date = bytes.u16(p + 14)
            let crc = bytes.u32(p + 16)
            let csize = Int(bytes.u32(p + 20))
            let usize = Int(bytes.u32(p + 24))
            let nameLen = Int(bytes.u16(p + 28))
            let extraLen = Int(bytes.u16(p + 30))
            let commentLen = Int(bytes.u16(p + 32))
            let ext = bytes.u32(p + 38)
            let local = Int(bytes.u32(p + 42))
            guard p + 46 + nameLen <= n else { throw ZipError.corrupt("file name") }
            let nameBytes = Array(bytes[(p + 46)..<(p + 46 + nameLen)])
            let name = String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            if flags & 0x0001 != 0 { throw ZipError.unsupported("encrypted files") }
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || local == 0xFFFF_FFFF {
                throw ZipError.unsupported("ZIP64 files (larger than 4 GB)")
            }
            guard local + 30 <= n, bytes.u32(local) == 0x04034b50 else { throw ZipError.corrupt("local header of \(name)") }
            let lName = Int(bytes.u16(local + 26))
            let lExtra = Int(bytes.u16(local + 28))
            let start = local + 30 + lName + lExtra
            guard start + csize <= n else { throw ZipError.corrupt("data of \(name)") }
            total += usize
            guard usize <= maxPartSize, total <= maxTotalSize else {
                throw ZipError.unsupported("parts over 1 GB or more than 4 GB unpacked in total")
            }
            entries.append(ZipEntry(name: name, method: method, flags: flags, modTime: time, modDate: date,
                                    crc32: crc, uncompressedSize: usize, externalAttributes: ext, rawData: []))
            spans.append(local..<(start + csize))
            dataRanges.append(start..<(start + csize))
            p += 46 + nameLen + extraLen + commentLen
        }
        // Entries sharing bytes would let a small file unpack into a huge one; check before copying.
        let sorted = spans.sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.lowerBound < a.upperBound {
            throw ZipError.corrupt("overlapping parts")
        }
        for i in entries.indices { entries[i].rawData = Array(bytes[dataRanges[i]]) }
        return entries
    }

    static func write(_ entries: [ZipEntry]) throws -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for e in entries {
            let nameBytes = Array(e.name.utf8)
            guard out.count < 0xFFFF_FFFF, e.rawData.count < 0xFFFF_FFFF, e.uncompressedSize < 0xFFFF_FFFF else {
                throw ZipError.unsupported("files larger than 4 GB")
            }
            // Sizes are written in the header, so no data descriptor (bit 3 cleared).
            let utf8Flag: UInt16 = nameBytes.contains(where: { $0 >= 0x80 }) ? 0x0800 : 0
            let flags: UInt16 = (e.flags & 0xFFF7) | utf8Flag
            let offset = UInt32(out.count)
            out.put32(0x04034b50); out.put16(20); out.put16(flags); out.put16(e.method)
            out.put16(e.modTime); out.put16(e.modDate); out.put32(e.crc32)
            out.put32(UInt32(e.rawData.count)); out.put32(UInt32(e.uncompressedSize))
            out.put16(UInt16(nameBytes.count)); out.put16(0)
            out += nameBytes
            out += e.rawData

            central.put32(0x02014b50); central.put16(20); central.put16(20); central.put16(flags)
            central.put16(e.method); central.put16(e.modTime); central.put16(e.modDate); central.put32(e.crc32)
            central.put32(UInt32(e.rawData.count)); central.put32(UInt32(e.uncompressedSize))
            central.put16(UInt16(nameBytes.count)); central.put16(0); central.put16(0)
            central.put16(0); central.put16(0); central.put32(e.externalAttributes); central.put32(offset)
            central += nameBytes
        }
        guard entries.count < 0xFFFF, out.count + central.count < 0xFFFF_FFFF else {
            throw ZipError.unsupported("too many or too large parts")
        }
        let cdOffset = UInt32(out.count)
        out += central
        out.put32(0x06054b50); out.put16(0); out.put16(0)
        out.put16(UInt16(entries.count)); out.put16(UInt16(entries.count))
        out.put32(UInt32(central.count)); out.put32(cdOffset); out.put16(0)
        return out
    }
}

enum Deflate {
    static func inflate(_ src: [UInt8], expectedSize: Int, name: String) throws -> [UInt8] {
        if expectedSize == 0 { return [] }
        guard !src.isEmpty else { throw ZipError.corrupt(name) }
        var dst = [UInt8](repeating: 0, count: expectedSize)
        let written = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, expectedSize, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corrupt(name) }
        return dst
    }

    /// Raw DEFLATE (what ZIP uses). Returns nil on failure.
    static func deflate(_ src: [UInt8]) -> [UInt8]? {
        guard !src.isEmpty else { return nil }
        let capacity = src.count + src.count / 8 + 1024
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, capacity, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Array(dst[0..<written])
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            let shifted: UInt32 = c >> 1
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ shifted) : shifted
        }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            let index: Int = Int((c ^ UInt32(b)) & 0xFF)
            c = table[index] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}

enum DosTime {
    static func now() -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980)
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let date: Int = (year << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: date))
    }
}

extension Array where Element == UInt8 {
    func u16(_ o: Int) -> UInt16 {
        let lo: UInt16 = UInt16(self[o])
        let hi: UInt16 = UInt16(self[o + 1]) << 8
        return lo | hi
    }
    func u32(_ o: Int) -> UInt32 {
        let b0: UInt32 = UInt32(self[o])
        let b1: UInt32 = UInt32(self[o + 1]) << 8
        let b2: UInt32 = UInt32(self[o + 2]) << 16
        let b3: UInt32 = UInt32(self[o + 3]) << 24
        return b0 | b1 | b2 | b3
    }
    mutating func put16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func put32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }
}
