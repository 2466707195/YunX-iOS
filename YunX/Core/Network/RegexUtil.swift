import Foundation

// MARK: - 正则小工具

/// 统一用 `NSRegularExpression`，不用 Swift 5.7 的正则字面量。
///
/// 理由很实际：这套识别规则是从 Android 版逐条搬过来的（Java/Kotlin 风格模式串），
/// 保持 `String` 形态的模式串最容易和上游对照，也不会踩字面量转义的地雷。
enum RegexUtil {

    /// 返回第 0..n 组捕获（第 0 组是整段匹配）。没有匹配返回 nil。
    static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for index in 0..<result.numberOfRanges {
            let groupRange = result.range(at: index)
            if groupRange.location == NSNotFound {
                groups.append("")
            } else if let swiftRange = Range(groupRange, in: text) {
                groups.append(String(text[swiftRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    static func firstGroup(_ pattern: String, in text: String, index: Int = 1) -> String? {
        guard let groups = match(pattern, in: text), groups.count > index else { return nil }
        let value = groups[index]
        return value.isEmpty ? nil : value
    }

    static func contains(_ pattern: String, in text: String) -> Bool {
        match(pattern, in: text) != nil
    }

    /// 所有匹配的指定分组（用于从页面里抠出多个直链）
    static func allGroups(_ pattern: String, in text: String, index: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let results = regex.matches(in: text, options: [], range: range)
        var output: [String] = []
        for result in results {
            guard result.numberOfRanges > index else { continue }
            let groupRange = result.range(at: index)
            if groupRange.location == NSNotFound { continue }
            if let swiftRange = Range(groupRange, in: text) {
                let value = String(text[swiftRange])
                if !value.isEmpty { output.append(value) }
            }
        }
        return output
    }
}

// MARK: - URL / 字符串工具

enum TextUtil {

    /// 分享文案里链接后面常跟中文标点，抓出来要先剪掉
    static let trailingCharacters = "。，,；;)]}\"'、！？…"

    /// 从任意文本里取第一个 http(s) 链接
    static func firstURL(in text: String) -> String? {
        guard let raw = RegexUtil.firstGroup("https?://[^\\s]+", in: text.trimmingCharacters(in: .whitespacesAndNewlines), index: 0) else {
            return nil
        }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: trailingCharacters))
    }

    /// 协议相对地址（`//host/path`）补成 https
    static func httpsURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        return "https://" + trimmed
    }

    /// 从 URL 里取查询参数
    static func queryValue(_ name: String, in url: String) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        return components.queryItems?.first { $0.name == name }?.value
    }

    /// 文件名兜底：标题为空时用平台 + id
    static func fileName(_ title: String, fallback: String, ext: String) -> String {
        let base = FileKind.sanitize(title.prefix(80).description)
        let cleaned = base.isEmpty ? fallback : base
        if ext.isEmpty { return cleaned }
        if cleaned.lowercased().hasSuffix("." + ext.lowercased()) { return cleaned }
        return "\(cleaned).\(ext)"
    }

    /// HTML 转义还原（标题里常见 `&amp;` `&#39;`）
    static func decodeHTMLEntities(_ text: String) -> String {
        var output = text
        let map = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#x27;": "'"
        ]
        for (key, value) in map {
            output = output.replacingOccurrences(of: key, with: value)
        }
        return output
    }
}
