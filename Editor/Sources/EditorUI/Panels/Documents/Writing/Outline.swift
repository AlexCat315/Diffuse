internal import Foundation
internal import EditorCore
internal import StudioDocuments
internal import GuavaUI
internal import GuavaUIRuntime

/// The front document's headings and counts. Choosing a heading puts the
/// caret on it; the heading under the caret is not tracked, only listed.
struct DocumentOutlinePanel: View {
    let app: EditorApplication
    private let observed: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    @State private var cache = OutlineCache()
    @State private var filter: TextBuffer = ""

    init(app: EditorApplication) {
        self.app = app
        observed = Observed(\.snapshot, on: app.workstation.documents)
    }

    var body: some View {
        let document = observed.wrappedValue.selected
        Column(alignment: .leading, spacing: 0) {
            if let document {
                let kind = DocumentKind(path: document.path, languages: app.languageCatalog)
                let hasOutline = kind.isMarkdown
                    || !app.languageCatalog.outlineRules(forLanguageID: kind.languageID).isEmpty
                if hasOutline {
                    let outline = cache.outline(for: document.text, languageID: kind.languageID, rules: app.languageCatalog.outlineRules(forLanguageID: kind.languageID))
                    let query = filter.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
                    let headings = query.isEmpty ? outline.headings : outline.headings.filter { $0.title.lowercased().contains(query) }
                    EditorPanelSearchBar(L("Filter headings"), text: $filter, summary: "\(outline.headings.count)")
                    summary(outline.statistics)
                    if outline.headings.isEmpty {
                        EditorPanelEmptyState(
                            L("No headings"),
                            detail: kind.isMarkdown
                                ? L("Start a line with # to add a heading.")
                                : L("No headings in this document.")
                        ).flex()
                    } else {
                        ScrollView(.vertical, scrollbarGutter: .stable) {
                            Column(alignment: .leading, spacing: 1) {
                                let base = outline.headings.map(\.level).min() ?? 1
                                for heading in headings {
                                    AnyView(row(heading, depth: heading.level - base, path: document.path))
                                }
                            }.padding(vertical: 4).frame(width: .percent(100), minWidth: 0)
                        }.flex().frame(minWidth: 0, minHeight: 0)
                    }
                } else {
                    summary(cache.outline(for: document.text, languageID: kind.languageID, rules: app.languageCatalog.outlineRules(forLanguageID: kind.languageID)).statistics)
                    EditorPanelEmptyState(L("No outline"), detail: L("This document has no outline.")).flex()
                }
            } else {
                EditorPanelEmptyState(L("No document"), detail: L("Open a Markdown file to see its outline.")).flex()
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .debugName("document-outline")
    }

    private func summary(_ statistics: DocumentStatistics) -> some View {
        Row(alignment: .center, spacing: 0) {
            metric("\(statistics.words)", L("Words"))
            metric("\(statistics.characters)", L("Characters"))
            metric("\(statistics.paragraphs)", L("Paragraphs"))
            metric("\(statistics.readingMinutes)", L("Min read"))
        }.padding(horizontal: 8, vertical: 6)
            .debugName("document-outline-statistics")
    }

    private func metric(_ value: String, _ label: String) -> some View {
        Column(alignment: .center, spacing: 1) {
            Text(value, lineLimit: 1).font(.bodyStrong).foregroundColor(.onSurface)
            Text(label, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
        }.padding(vertical: 6).flex(1, shrink: 1).frame(minWidth: 0)
            .background(.surfaceRaised).cornerRadius(8).padding(horizontal: 2)
    }

    private func row(_ heading: DocumentHeading, depth: Int, path: String) -> some View {
        Button(tooltip: heading.title) {
            app.workstation.documents.reveal(path, characterIndex: heading.characterIndex)
            EditorWorkbenchLink.of(app).show("documents")
        } label: {
            Row(alignment: .center, spacing: 6) {
                Text(heading.title, lineLimit: 1)
                    .font(depth == 0 ? .bodyStrong : .body)
                    .foregroundColor(depth == 0 ? .onSurface : .onSurfaceVariant)
                    .flex(1, shrink: 1).frame(minWidth: 0)
                Text("H\(heading.level)").font(.caption).foregroundColor(.onSurfaceMuted)
            }.padding(EdgeInsets(leading: 12 + Float(min(depth, 5)) * 14, trailing: 10)).frame(width: .percent(100), height: .points(26))
        }.buttonStyle(.plain).frame(width: .percent(100), minWidth: 0)
            .debugName("document-outline-heading-\(heading.characterIndex)")
    }
}

/// Parsing walks the whole text, so it runs once per document revision.
private final class OutlineCache {
    struct Outline {
        var headings: [DocumentHeading] = []
        var statistics = DocumentStatistics(Substring(""))
    }

    private var text: String?
    private var languageID: String?
    private var rules: [LanguageOutlineRule] = []
    private var value = Outline()

    func outline(for text: String, languageID: String?, rules: [LanguageOutlineRule]) -> Outline {
        guard self.text != text || self.languageID != languageID || self.rules != rules else { return value }
        self.text = text
        self.languageID = languageID
        self.rules = rules
        let headings = languageID == "markdown"
            ? DocumentHeading.parse(text)
            : DocumentHeading.parse(text, rules: rules)
        value = Outline(headings: headings, statistics: DocumentStatistics(Substring(text)))
        return value
    }
}
