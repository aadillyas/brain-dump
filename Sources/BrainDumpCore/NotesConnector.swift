import Foundation

public struct NotesConnector: Connector {
    public let id = "notes"
    public let name = "Notes"
    public let store: NotesStore

    public init(store: NotesStore) { self.store = store }

    public func handles(_ kind: ItemKind) -> Bool { !kind.isActionable }

    public func destination(for item: ExtractedItem) -> String {
        item.kind == .idea ? "Notes › Ideas" : "Notes › Thoughts"
    }

    public func execute(_ item: ExtractedItem, context: ActionContext) async throws -> ActionResult {
        let ref = try store.createNote(
            kind: item.kind, title: item.title, body: item.quote, journal: context.journal, date: context.now)
        let label = item.kind == .idea ? "Idea" : "Thought"
        return ActionResult(
            itemID: item.id, connectorID: id, summary: "\(label) saved: \(item.title)",
            undoToken: ref.url.path, openURL: ref.url)
    }

    public func undo(_ result: ActionResult) async throws {
        guard let path = result.undoToken else { return }
        try store.delete(NoteRef(url: URL(fileURLWithPath: path), wikiLink: ""))
    }
}
