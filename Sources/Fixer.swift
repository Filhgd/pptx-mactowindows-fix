import Foundation

struct FixedImage {
    let oldPath: String
    let newPath: String
    let width: Int
    let height: Int
}

enum FixError: Error, CustomStringConvertible {
    case notPresentation
    case imageFailed(String, Error)
    case verifyFailed(String)

    var description: String {
        switch self {
        case .notPresentation: return "This is not a PowerPoint presentation (.pptx)."
        case .imageFailed(let name, let err): return "Image \(name) could not be converted: \(err)"
        case .verifyFailed(let s): return "Check of the new file failed: \(s)"
        }
    }
}

enum PPTXFixer {
    static let targetPPI: Double = 300
    static let maxSidePx: Double = 5000
    static let emuPerInch: Double = 914_400

    /// Pasted PDF clips that Windows would show blurry. Empty = nothing to fix.
    static func findClips(in entries: [ZipEntry]) throws -> [String: [UInt8]] {
        var clips: [String: [UInt8]] = [:]
        for e in entries where e.name.lowercased().hasPrefix("ppt/") && e.name.lowercased().hasSuffix(".emf") {
            if let pdf = EMF.embeddedPDF(try e.contents()) { clips[e.name] = pdf }
        }
        return clips
    }

    /// Writes a fixed copy to `output`. Returns the images that were replaced;
    /// when that list is empty nothing was written.
    static func fix(input: URL, output: URL) throws -> [FixedImage] {
        let bytes = [UInt8](try Data(contentsOf: input))
        let entries = try ZipArchive.read(bytes)
        let names = Set(entries.map { $0.name })
        guard names.contains("[Content_Types].xml"), names.contains("ppt/presentation.xml") else {
            throw FixError.notPresentation
        }
        let clips = try findClips(in: entries)
        if clips.isEmpty { return [] }

        let widths = try displayWidths(entries)
        var usedNames = names
        var replacement: [String: (newPath: String, png: [UInt8])] = [:]
        var fixed: [FixedImage] = []

        for path in clips.keys.sorted() {
            let pdf = clips[path]!
            guard let size = PDFRender.pageSize(pdf), size.width > 0, size.height > 0 else {
                throw FixError.imageFailed(path, RenderError.badPDF)
            }
            // Resolution: 300 ppi at the largest size it is shown on a slide,
            // or 300 ppi at the clip's own size when it is not placed as a picture.
            var widthPx = (widths[path] ?? Double(size.width) / 72) * targetPPI
            let longest = max(widthPx, widthPx * Double(size.height) / Double(size.width))
            if longest > maxSidePx { widthPx *= maxSidePx / longest }
            widthPx = max(widthPx, 16)

            let rendered: (data: [UInt8], width: Int, height: Int)
            do { rendered = try PDFRender.png(pdf, widthPx: Int(widthPx.rounded())) }
            catch { throw FixError.imageFailed(path, error) }

            let base = (path as NSString).deletingPathExtension
            var newPath = base + "_hr.png"
            var n = 2
            while usedNames.contains(newPath) { newPath = base + "_hr\(n).png"; n += 1 }
            usedNames.insert(newPath)
            replacement[path] = (newPath, rendered.data)
            fixed.append(FixedImage(oldPath: path, newPath: newPath, width: rendered.width, height: rendered.height))
        }

        var out: [ZipEntry] = []
        for e in entries {
            if let r = replacement[e.name] {
                out.append(ZipEntry.make(name: r.newPath, contents: r.png, like: e))
            } else if e.name.hasSuffix(".rels") {
                let xml = try string(e)
                let newXML = rewriteRels(xml, relsPath: e.name, replacement.mapValues { $0.newPath })
                out.append(newXML == xml ? e : ZipEntry.make(name: e.name, contents: Array(newXML.utf8), like: e))
            } else if e.name == "[Content_Types].xml" {
                let xml = try string(e)
                let newXML = updateContentTypes(xml, removed: Array(replacement.keys))
                out.append(newXML == xml ? e : ZipEntry.make(name: e.name, contents: Array(newXML.utf8), like: e))
            } else {
                out.append(e)
            }
        }

        let result = try ZipArchive.write(out)
        try verify(result, removed: Set(replacement.keys))

        // Write next to the destination first, then move into place.
        let dir = output.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".~pptxfix-\(UUID().uuidString).tmp")
        try Data(result).write(to: temp)
        do {
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return fixed
    }

    // MARK: - Checks

    /// Reads the new file back: every part must decompress with the right checksum,
    /// XML must still be UTF-8 and no relationship may point at a removed image.
    static func verify(_ bytes: [UInt8], removed: Set<String>) throws {
        let entries = try ZipArchive.read(bytes)
        guard entries.first?.name == "[Content_Types].xml" || entries.contains(where: { $0.name == "[Content_Types].xml" })
        else { throw FixError.verifyFailed("[Content_Types].xml is missing") }
        var names = Set<String>()
        for e in entries {
            let c = try e.contents()
            guard CRC32.checksum(c) == e.crc32 else { throw FixError.verifyFailed("checksum of \(e.name)") }
            names.insert(e.name)
            if e.name.hasSuffix(".rels") {
                guard let xml = String(bytes: c, encoding: .utf8) else { throw FixError.verifyFailed(e.name) }
                for (_, target) in relationships(xml, relsPath: e.name) where removed.contains(target) {
                    throw FixError.verifyFailed("\(e.name) still points to \(target)")
                }
            }
        }
        for r in removed where names.contains(r) { throw FixError.verifyFailed("\(r) is still present") }
    }

    // MARK: - Sizes on the slides

    /// Largest width (inches, uncropped) at which each media part is shown.
    static func displayWidths(_ entries: [ZipEntry]) throws -> [String: Double] {
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let partPattern = try NSRegularExpression(pattern: #"^ppt/(slides|slideLayouts|slideMasters)/[^/]+\.xml$"#)
        let picPattern = try NSRegularExpression(pattern: #"<p:pic\b.*?</p:pic>"#, options: [.dotMatchesLineSeparators])
        var widths: [String: Double] = [:]

        for e in entries where partPattern.firstMatch(in: e.name, range: NSRange(e.name.startIndex..., in: e.name)) != nil {
            let dir = (e.name as NSString).deletingLastPathComponent
            let relsName = dir + "/_rels/" + (e.name as NSString).lastPathComponent + ".rels"
            guard let relsEntry = byName[relsName] else { continue }
            let rels = Dictionary(relationships(try string(relsEntry), relsPath: relsName), uniquingKeysWith: { a, _ in a })
            let xml = try string(e)
            for m in picPattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
                guard let r = Range(m.range, in: xml) else { continue }
                let pic = String(xml[r])
                guard let rid = firstGroup(#"r:embed="([^"]+)""#, pic), let target = rels[rid],
                      let cx = firstGroup(#"<a:ext cx="(\d+)""#, pic).flatMap(Double.init) else { continue }
                var visible = 1.0
                if let crop = firstGroup(#"<a:srcRect([^>]*)>"#, pic) {
                    let l = firstGroup(#"\bl="(-?\d+)""#, crop).flatMap(Double.init) ?? 0
                    let rr = firstGroup(#"\br="(-?\d+)""#, crop).flatMap(Double.init) ?? 0
                    visible = max(0.05, 1 - (l + rr) / 100_000)
                }
                let inches = cx / emuPerInch / visible
                widths[target] = max(widths[target] ?? 0, inches)
            }
        }
        return widths
    }

    // MARK: - Relationships and content types

    /// (Id, resolved part name) for every internal relationship in a .rels file.
    static func relationships(_ xml: String, relsPath: String) -> [(String, String)] {
        let base = relsBaseDir(relsPath)
        var result: [(String, String)] = []
        for tag in allMatches(#"<Relationship\b[^>]*>"#, xml) {
            if tag.contains(#"TargetMode="External""#) { continue }
            guard let id = firstGroup(#"\bId="([^"]*)""#, tag),
                  let target = firstGroup(#"\bTarget="([^"]*)""#, tag) else { continue }
            result.append((id, resolve(target, base: base)))
        }
        return result
    }

    static func rewriteRels(_ xml: String, relsPath: String, _ map: [String: String]) -> String {
        if map.isEmpty { return xml }
        let base = relsBaseDir(relsPath)
        var out = xml
        for tag in Set(allMatches(#"<Relationship\b[^>]*>"#, xml)) {
            if tag.contains(#"TargetMode="External""#) { continue }
            guard let target = firstGroup(#"\bTarget="([^"]*)""#, tag),
                  let newPath = map[resolve(target, base: base)] else { continue }
            let newName = (newPath as NSString).lastPathComponent
            var parts = target.components(separatedBy: "/")
            parts[parts.count - 1] = newName
            let newTag = tag.replacingOccurrences(of: #"Target="\#(target)""#, with: #"Target="\#(parts.joined(separator: "/"))""#)
            out = out.replacingOccurrences(of: tag, with: newTag)
        }
        return out
    }

    static func updateContentTypes(_ xml: String, removed: [String]) -> String {
        var out = xml
        for path in removed {
            for tag in allMatches(#"<Override\b[^>]*/>"#, out) where tag.contains(#"PartName="/\#(path)""#) {
                out = out.replacingOccurrences(of: tag, with: "")
            }
        }
        if out.range(of: #"Extension="png""#, options: .caseInsensitive) == nil,
           let open = out.range(of: #"<Types\b[^>]*>"#, options: .regularExpression) {
            out.insert(contentsOf: #"<Default Extension="png" ContentType="image/png"/>"#, at: open.upperBound)
        }
        return out
    }

    // MARK: - Helpers

    static func relsBaseDir(_ relsPath: String) -> String {
        // "ppt/slides/_rels/slide1.xml.rels" -> "ppt/slides/"; "_rels/.rels" -> ""
        var parts = relsPath.components(separatedBy: "/")
        guard parts.count >= 2 else { return "" }
        parts.removeLast(2)
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }

    static func resolve(_ target: String, base: String) -> String {
        let t = target.removingPercentEncoding ?? target
        let full = t.hasPrefix("/") ? String(t.dropFirst()) : base + t
        var stack: [String] = []
        for p in full.components(separatedBy: "/") {
            if p == "" || p == "." { continue }
            if p == ".." { if !stack.isEmpty { stack.removeLast() } } else { stack.append(p) }
        }
        return stack.joined(separator: "/")
    }

    static func string(_ e: ZipEntry) throws -> String {
        let c = try e.contents()
        return String(bytes: c, encoding: .utf8) ?? String(decoding: c, as: UTF8.self)
    }

    static func firstGroup(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func allMatches(_ pattern: String, _ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range, in: s).map { String(s[$0]) }
        }
    }
}
