import AppKit
import Combine
import FrescobaldiCore
import SwiftUI

final class OutlineModel: ObservableObject {
    @Published var items: [OutlineItem] = []
    @Published var selection: OutlineItem.ID?
    var onSelect: ((OutlineItem) -> Void)?

    func update(text: NSString) {
        let new = DocumentOutline.items(in: text)
        if new != items { items = new }
    }
}

extension OutlineItem {
    var symbol: String {
        switch kind {
        case .assignment: "equal.square"
        case .score: "music.note.list"
        case .header: "textformat"
        case .book: "book.closed"
        case .bookpart: "book"
        case .paper: "doc"
        case .layout: "rectangle.3.group"
        case .midi: "pianokeys"
        case .include: "doc.badge.plus"
        case .version: "number"
        case .marker: "bookmark"
        }
    }
}

struct OutlineSidebarView: View {
    @ObservedObject var model: OutlineModel

    var body: some View {
        Group {
            if model.items.isEmpty {
                ContentUnavailableView("No Outline", systemImage: "list.bullet.indent",
                                       description: Text("Variables, scores and %% markers appear here."))
            } else {
                List(selection: $model.selection) {
                    ForEach(model.items) { item in
                        Label {
                            Text(item.title)
                                .lineLimit(1)
                                .help("Line \(item.line)")
                        } icon: {
                            Image(systemName: item.symbol)
                                .foregroundStyle(item.kind == .marker ? Color.accentColor : Color.secondary)
                        }
                        .padding(.leading, CGFloat(item.level) * 12)
                        .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onChange(of: model.selection) { _, id in
            guard let id, let item = model.items.first(where: { $0.id == id }) else { return }
            model.onSelect?(item)
        }
    }
}
