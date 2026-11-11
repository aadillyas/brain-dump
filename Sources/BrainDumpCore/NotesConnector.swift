import Foundation

public struct NotesConnector: Connector {
    public let id = "notes"
    public let name = "Notes"
    public let store: NotesStore

    public init(store: NotesStore) { self.store = store }

    public func destination(for item: ExtractedItem, category: ItemCategory) -> String {
        "Notes › \(category.folder)"
    }

    public func execute(_ item: ExtractedItem, context: ActionContext) async throws -> ActionResult {
        if let target = item.addTo {
            let previous = try store.appendMention(to: target, quote: item.quote, journal: context.journal, date: context.now)
            let title = RelatedNotes.parse(previous, fallback: target.deletingPathExtension().lastPathComponent).title
            return ActionResult(
                itemID: item.id, connectorID: id, summary: "\(context.category.name) added to: \(title)",
                undoToken: Self.mergePrefix + target.path + "\n" + previous, openURL: target)
        }
        let ref = try store.createNote(
            category: context.category, title: item.title, body: item.quote, journal: context.journal, date: context.now)
        return ActionResult(
            itemID: item.id, connectorID: id, summary: "\(context.category.name) saved: \(item.title)",
            undoToken: ref.url.path, openURL: ref.url)
    }

    /// Undo tokens for merges hold the note's path and its content before the merge.
    static let mergePrefix = "merge:"

    public func undo(_ result: ActionResult) async throws {
        guard let path = result.undoToken else { return }
        if path.hasPrefix(Self.mergePrefix), let newline = path.firstIndex(of: "\n") {
            let url = URL(fileURLWithPath: String(path[path.index(path.startIndex, offsetBy: Self.mergePrefix.count)..<newline]))
            try store.restore(url, content: String(path[path.index(after: newline)...]))
            return
        }
        try store.delete(NoteRef(url: URL(fileURLWithPath: path), wikiLink: ""))
    }
}
