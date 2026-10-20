import Foundation

/// InfoPlist.strings 是 UTF-16 的 OpenStep 风格文本（"key" = "value";）。
/// PropertyListSerialization 能读，但只会以 XML 写回、格式全变；
/// 所以这里用"正则替换 + 原编码写回"，最大限度保持文件原样。
enum StringsFile {
    static func read(_ url: URL) throws -> (text: String, encoding: String.Encoding) {
        var enc: UInt = 0
        let text = try NSString(contentsOf: url, usedEncoding: &enc)
        return (text as String, String.Encoding(rawValue: enc))
    }

    static func write(_ text: String, to url: URL, encoding: String.Encoding) throws {
        guard let data = text.data(using: encoding) else {
            throw StringsError.encodingFailed(url.path)
        }
        try data.write(to: url)
    }

    /// 替换 "KEY" = "VALUE"; 里 VALUE 的部分，其余一切（缩进、顺序、注释）不动。
    static func replacing(_ text: String, keys: [String], with value: String) -> String {
        var out = text
        for key in keys {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            let pattern = "\"\(escapedKey)\"\\s*=\\s*\"([^\"]*)\""
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let template = "\"\(key)\" = \"" + NSRegularExpression.escapedTemplate(for: value) + "\""
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }

    enum StringsError: Error, LocalizedError {
        case encodingFailed(String)
        var errorDescription: String? {
            switch self {
            case .encodingFailed(let p): return "无法以原编码写回：\(p)"
            }
        }
    }
}
