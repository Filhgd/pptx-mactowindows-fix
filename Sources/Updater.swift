import Foundation

/// Checks GitHub for a newer release. Only reads the public "latest release" page;
/// nothing about the user or their files is sent.
struct ReleaseInfo {
    let version: String      // "1.2.0" (without the leading "v")
    let pageURL: URL         // release page on GitHub
    let downloadURL: URL?    // the macOS zip, when attached
    let notes: String
}

enum UpdateError: Error, CustomStringConvertible {
    case http(Int)
    case badResponse

    var description: String {
        switch self {
        case .http(404): return "no release found on GitHub"
        case .http(403), .http(429): return "GitHub is limiting requests, try again later"
        case .http(let code): return "GitHub answered with error \(code)"
        case .badResponse: return "unexpected answer from GitHub"
        }
    }
}

enum Updater {
    static let repository = "Filhgd/pptx-mactowindows-fix"
    static let defaultURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// PPTXFIX_RELEASES_URL overrides the address (used by the tests).
    static var releasesURL: URL {
        ProcessInfo.processInfo.environment["PPTXFIX_RELEASES_URL"].flatMap { URL(string: $0) } ?? defaultURL
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "v1.10.2" -> [1, 10, 2]; anything after the digits of a part is ignored ("2-beta" -> 2).
    static func numbers(_ version: String) -> [Int] {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v.split(separator: ".").map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap({ URL(string: $0) }) else {
            throw UpdateError.badResponse
        }
        var download: URL? = nil
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String, name.hasSuffix("-macOS.zip"),
                   let s = asset["browser_download_url"] as? String, let u = URL(string: s) {
                    download = u
                    break
                }
            }
        }
        var version = tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return ReleaseInfo(version: version, pageURL: page, downloadURL: download,
                           notes: (json["body"] as? String) ?? "")
    }

    static func fetchLatest(completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        var request = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PPTXMacToWindowsFix/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(UpdateError.http(http.statusCode)))
                return
            }
            guard let data else { completion(.failure(UpdateError.badResponse)); return }
            completion(Result { try parse(data) })
        }.resume()
    }

    /// Release notes as plain text for a dialog: markdown symbols removed, shortened.
    static func plainNotes(_ markdown: String, limit: Int = 700) -> String {
        var lines: [String] = []
        for raw in markdown.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text
    }
}
