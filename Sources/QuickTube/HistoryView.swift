import AppKit
import QuickTubeCore
import SwiftUI

/// Every link in the history, newest first, opened by "Show All…" under Recent Links.
struct HistoryView: View {
    static let windowID = "history"

    let model: AppModel
    @State private var query = ""
    /// The row whose link was just copied; shows "Copied" for a moment.
    @State private var copiedID: HistoryItem.ID?

    private var items: [HistoryItem] { model.state.history.filter { $0.matches(query) } }

    var body: some View {
        content
            .searchable(text: $query, placement: .toolbar, prompt: "Title, destination or link")
            .safeAreaInset(edge: .bottom) { footer }
            .frame(minWidth: 480, minHeight: 320)
    }

    @ViewBuilder private var content: some View {
        if model.state.history.isEmpty {
            ContentUnavailableView(
                "No Links Yet", systemImage: "clock",
                description: Text(
                    model.settings.historyEnabled
                        ? "Uploaded links and saved files appear here."
                        : "History is off. Turn on Keep recent links in Settings."))
        } else if items.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(items) { item in
                HistoryRow(
                    item: item, copied: copiedID == item.id,
                    copy: { copy(item) }, open: { model.openHistoryLink(item.link) },
                    remove: { model.state.removeHistory(id: item.id) })
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var footer: some View {
        HStack {
            Text(countText).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Clear History") { model.state.clearHistory() }
                .disabled(model.state.history.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var countText: String {
        let total = model.state.history.count
        let noun = total == 1 ? "link" : "links"
        return items.count == total ? "\(total) \(noun)" : "\(items.count) of \(total) \(noun)"
    }

    private func copy(_ item: HistoryItem) {
        model.copyToPasteboard(item.link)
        copiedID = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedID == item.id { copiedID = nil }
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let copied: Bool
    let copy: () -> Void
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.destination.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    Text(item.displayHost).lineLimit(1).truncationMode(.middle)
                    if let detail = item.detailText() {
                        Text("· \(detail)").monospacedDigit().fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(dateText).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if copied {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .transition(.opacity)
            }
            Button(action: copy) { Image(systemName: "doc.on.doc") }
                .help("Copy Link")
            Button(action: open) {
                Image(systemName: item.link.isFileURL ? "folder" : "arrow.up.right.square")
            }
            .help(item.link.isFileURL ? "Show in Finder" : "Open in Browser")
            Button(action: remove) { Image(systemName: "trash") }
                .help("Remove")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .animation(.default, value: copied)
        .contextMenu {
            Button("Copy Link", action: copy)
            Button(item.link.isFileURL ? "Show in Finder" : "Open", action: open)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
    }

    /// "2 hours ago · Nov 10, 2026 at 14:05".
    private var dateText: String {
        let relative = item.date.formatted(.relative(presentation: .named))
        return "\(relative) · \(item.date.formatted(date: .abbreviated, time: .shortened))"
    }
}
