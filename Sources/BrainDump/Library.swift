import Foundation
import SwiftUI

struct MarkdownBlock: Identifiable {
    enum Kind { case heading(Int), bullet(String), quote, paragraph }
    let id = UUID()
    let kind: Kind
    let attributed: AttributedString
}

enum Markdown {
    /// Returns frontmatter as small "key: value" strings, and the remaining body.
    static func splitFrontmatter(_ text: String) -> ([String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([], text) }
        let meta = lines[1..<end].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (meta, lines[(end + 1)...].joined(separator: "\n"))
    }

    static func blocks(_ body: String, linkExists: (String) -> Bool) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var para: [String] = []
        func flush() {
            guard !para.isEmpty else { return }
            out.append(MarkdownBlock(kind: .paragraph, attributed: inline(para.joined(separator: " "), linkExists)))
            para = []
        }
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            let afterHashes = line.dropFirst(hashes)
            let digits = line.prefix(while: \.isNumber)
            let afterDigits = line.dropFirst(digits.count)
            if (1...6).contains(hashes), afterHashes.first == " " {
                flush()
                out.append(MarkdownBlock(kind: .heading(hashes), attributed: inline(afterHashes.trimmingCharacters(in: .whitespaces), linkExists)))
            } else if let f = line.first, "-*+".contains(f), line.dropFirst().first == " " {
                flush()
                out.append(MarkdownBlock(kind: .bullet("•"), attributed: inline(line.dropFirst(2).trimmingCharacters(in: .whitespaces), linkExists)))
            } else if !digits.isEmpty, let p = afterDigits.first, p == "." || p == ")", afterDigits.dropFirst().first == " " {
                flush()
                out.append(MarkdownBlock(kind: .bullet("\(digits)."), attributed: inline(afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces), linkExists)))
            } else if line.hasPrefix(">") {
                flush()
                out.append(MarkdownBlock(kind: .quote, attributed: inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces), linkExists)))
            } else {
                para.append(line)
            }
        }
        flush()
        return out
    }

    /// Bold, italic, code and links via AttributedString; `[[wiki]]` links become bdnote: links when the file exists.
    static func inline(_ text: String, _ linkExists: (String) -> Bool) -> AttributedString {
        var s = text
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        if let re = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#) {
            let ns = s as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                last = m.range.location + m.range.length
                let target = ns.substring(with: m.range(at: 1))
                let label = m.range(at: 2).location == NSNotFound ? target : ns.substring(with: m.range(at: 2))
                if linkExists(target) {
                    result += "[\(label)](bdnote:\(target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target))"
                } else {
                    result += label
                }
            }
            s = result + ns.substring(from: last)
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
