import Foundation

/// PowerPoint for Mac stores a pasted PDF clip as an EMF with two versions inside:
///  - an EMR_COMMENT "GDIC" (EMR_COMMENT_MULTIFORMATS) record holding the original PDF (read by the Mac)
///  - a low-resolution bitmap (EMF+ or GDI records), which is what Windows shows.
/// This returns the PDF, or nil when the EMF does not contain one.
enum EMF {
    static func embeddedPDF(_ d: [UInt8]) -> [UInt8]? {
        guard d.count >= 8, d.u32(0) == 1 else { return nil }   // must start with EMR_HEADER
        var off = 0
        while off + 8 <= d.count {
            let type = d.u32(off)
            let size = Int(d.u32(off + 4))
            guard size >= 8, off + size <= d.count else { break }
            if type == 70, size >= 16 {                          // EMR_COMMENT
                let dataSize = Int(d.u32(off + 8))
                let bodyStart = off + 12
                let bodyEnd = min(bodyStart + dataSize, off + size)
                if bodyEnd - bodyStart >= 4, Array(d[bodyStart..<(bodyStart + 4)]) == Array("GDIC".utf8),
                   let pdf = pdfInMultiformats(d, bodyStart, bodyEnd) {
                    return pdf
                }
            }
            if type == 14 { break }                                  // EMR_EOF
            off += size
        }
        return nil
    }

    /// Body layout: "GDIC", 0x40000004, bounds (16 bytes), count, then count x
    /// (signature, version, cbData, offData), with offData counted from "GDIC".
    private static func pdfInMultiformats(_ d: [UInt8], _ start: Int, _ end: Int) -> [UInt8]? {
        let pdfMagic = Array("%PDF".utf8)
        if end - start >= 28, d.u32(start + 4) == 0x4000_0004 {
            let count = Int(d.u32(start + 24))
            if count > 0 && count < 64 {
                for i in 0..<count {
                    let f = start + 28 + i * 16
                    guard f + 16 <= end else { break }
                    let cb = Int(d.u32(f + 8))
                    let offData = Int(d.u32(f + 12))
                    let s = start + offData
                    if cb > 4, s >= start, s + cb <= end, Array(d[s..<(s + 4)]) == pdfMagic {
                        return Array(d[s..<(s + cb)])
                    }
                }
            }
        }
        // Fallback: search for the PDF markers.
        guard let p = find(pdfMagic, in: d, from: start, to: end) else { return nil }
        let eof = Array("%%EOF".utf8)
        var last: Int? = nil
        var q = p
        while let hit = find(eof, in: d, from: q, to: end) { last = hit; q = hit + 1 }
        guard let e = last else { return nil }
        return Array(d[p..<(e + eof.count)])
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int, to: Int) -> Int? {
        guard needle.count > 0, to - from >= needle.count else { return nil }
        var i = from
        let last = to - needle.count
        while i <= last {
            if hay[i] == needle[0] {
                var ok = true
                for j in 1..<needle.count where hay[i + j] != needle[j] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }
}
