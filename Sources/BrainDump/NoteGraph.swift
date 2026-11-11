import BrainDumpCore
import Foundation

/// Pure model of how notes link to each other: nodes are notes (optionally journal days), edges come from `## Related` bullets.
struct NoteGraph: Sendable {
    struct Node: Identifiable, Hashable, Sendable {
        /// Wiki link without extension, e.g. "Ideas/morning-walks".
        let id: String
        let title: String
        let kind: ItemKind
        let mentions: Int
        let url: URL
        let updated: Date
        let isJournal: Bool
    }

    struct Edge: Hashable, Sendable {
        let from: String
        let to: String
        let reason: String?
    }

    var nodes: [Node] = []
    var edges: [Edge] = []

    static let journalKind = ItemKind("journal")

    /// Reads every note in `folders` under `root`. Blocking file IO: call off the main thread.
    static func load(root: URL, folders: [String], includeJournal: Bool = false) -> NoteGraph {
        let fm = FileManager.default
        var nodes: [String: Node] = [:]
        var order: [String] = []
        var raws: [String: String] = [:]

        for folder in folders {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files.filter({ $0.pathExtension == "md" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let slug = url.deletingPathExtension().lastPathComponent
                let id = "\(folder)/\(slug)"
                guard nodes[id] == nil else { continue }
                let front = frontmatter(raw)
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let updated = front["updated"].flatMap(parseDate) ?? front["created"].flatMap(parseDate) ?? mtime ?? .distantPast
                nodes[id] = Node(id: id, title: RelatedNotes.parse(raw, fallback: slug).title,
                                 kind: ItemKind(front["type"] ?? ""), mentions: max(1, Int(front["mentions"] ?? "") ?? 1),
                                 url: url, updated: updated, isJournal: false)
                order.append(id)
                raws[id] = raw
            }
        }

        // Slug-only links resolve to the first note with that slug.
        var bySlug: [String: String] = [:]
        for id in order { bySlug[String(id.split(separator: "/").last ?? ""), default: id] = id }

        var edges: [Edge] = []
        var edgeIndex: [String: Int] = [:]
        func addEdge(_ a: String, _ b: String, _ reason: String?) {
            guard a != b else { return }
            let key = a < b ? "\(a)\u{0}\(b)" : "\(b)\u{0}\(a)"
            if let i = edgeIndex[key] {
                if edges[i].reason == nil, let reason { edges[i] = Edge(from: edges[i].from, to: edges[i].to, reason: reason) }
            } else {
                edgeIndex[key] = edges.count
                edges.append(Edge(from: a, to: b, reason: reason))
            }
        }

        for id in order {
            for (target, reason) in relatedLinks(in: raws[id] ?? "") {
                let resolved = nodes[target] != nil ? target : bySlug[target]
                if let resolved { addEdge(id, resolved, reason) }
            }
        }

        if includeJournal {
            let re = try? NSRegularExpression(pattern: #"\[\[Journal/(\d{4}-\d{2}-\d{2})[^\]]*\]\]"#)
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            day.locale = Locale(identifier: "en_US_POSIX")
            for id in order {
                let raw = raws[id] ?? ""
                let ns = raw as NSString
                for m in re?.matches(in: raw, range: NSRange(location: 0, length: ns.length)) ?? [] {
                    let d = ns.substring(with: m.range(at: 1))
                    let jid = "Journal/\(d)"
                    if nodes[jid] == nil {
                        let url = root.appendingPathComponent("Journal/\(d).md")
                        guard fm.fileExists(atPath: url.path) else { continue }
                        nodes[jid] = Node(id: jid, title: d, kind: journalKind, mentions: 1, url: url,
                                          updated: day.date(from: d) ?? .distantPast, isJournal: true)
                        order.append(jid)
                    }
                    addEdge(id, jid, nil)
                }
            }
        }
        return NoteGraph(nodes: order.compactMap { nodes[$0] }, edges: edges)
    }

    /// Top-level "key: value" pairs of the YAML-ish frontmatter, trailing "# comments" removed.
    static func frontmatter(_ raw: String) -> [String: String] {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return [:] }
        var out: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...])
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            out[key] = value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        }
        return out
    }

    /// `[[target]]` bullets under `## Related`, with the optional reason after a dash. Anchors and aliases are stripped.
    static func relatedLinks(in raw: String) -> [(target: String, reason: String?)] {
        guard let re = try? NSRegularExpression(pattern: #"^\s*[-*]\s*\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]\s*(?:[—–-]+\s*(.*))?$"#) else { return [] }
        var inRelated = false
        var out: [(String, String?)] = []
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inRelated = line.hasPrefix("## Related"); continue }
            guard inRelated else { continue }
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            var reason: String?
            if m.range(at: 2).location != NSNotFound {
                let r = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                reason = r.isEmpty ? nil : r
            }
            out.append((target, reason))
        }
        return out
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
