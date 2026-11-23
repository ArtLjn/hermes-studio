import Foundation

public struct GroupSharedPage: Encodable, Sendable {
    public let status: Int
    public let title: String?
    public let text: String
    public let truncated: Bool
    public let note: String?

    public static func requestedURL(in text: String) -> URL? {
        guard ["打开", "看一下", "看下", "看看", "读一下", "阅读", "查看"].contains(where: text.contains),
            !["不要", "别打开", "不用打开", "示例", "例子", "如果"].contains(where: text.contains),
            let match = text.range(of: #"https?://[^\s<>「」]+"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let raw = String(text[match]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、！）】”\"',"))
        return authorizedURL(raw)
    }

    static func authorizedURL(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
            ["https", "http"].contains(scheme), parts.host?.isEmpty == false,
            parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    public static func read(_ url: URL) async throws -> Self {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw StudioError.message("链接未返回 HTTP 响应。") }
        if (300..<400).contains(http.statusCode) {
            return Self(status: http.statusCode, title: nil, text: "", truncated: false,
                note: "页面返回了重定向，可以在浏览器里继续打开。")
        }
        let type = http.mimeType ?? ""
        guard type.hasPrefix("text/") || ["application/xhtml+xml", "application/json"].contains(type) else {
            return Self(status: http.statusCode, title: nil, text: "", truncated: false,
                note: "这是非文本内容，可以在浏览器里打开。")
        }
        var data = Data()
        var truncated = false
        for try await byte in bytes {
            if data.count >= 131_072 { truncated = true; break }
            data.append(byte)
        }
        let body = String(decoding: data, as: UTF8.self)
        let html = type.contains("html")
        let title = html ? body.range(of: #"(?is)<title\b[^>]*>.*?</title>"#, options: .regularExpression)
            .map { Self.plainText(String(body[$0])) } : nil
        let withoutScripts = html ? body.replacingOccurrences(of: #"(?is)<(script|style|head)\b[^>]*>.*?</\1\s*>"#,
            with: " ", options: .regularExpression) : body
        let text = html ? plainText(withoutScripts) : withoutScripts
        return Self(status: http.statusCode, title: title.map { String($0.prefix(240)) },
            text: String(text.prefix(6_000)), truncated: truncated || text.count > 6_000,
            note: html && text.isEmpty ? "页面没有可提取的正文，内容可能需要在浏览器里运行脚本。" : nil)
    }

    private static func plainText(_ html: String) -> String {
        let text = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
