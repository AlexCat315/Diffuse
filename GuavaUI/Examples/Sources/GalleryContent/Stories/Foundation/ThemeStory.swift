import GuavaUI
import GuavaUIRuntime

private struct EditorialTokens: ThemeExtension {
    var figure = TextStyleToken(font: .system(size: 30, weight: .bold), lineHeight: 38, letterSpacing: -0.5)
    var cardInset: Float = 24
    static let defaultValue = EditorialTokens()
}

struct ThemeStory: View {
    @State private var bodySize: Double = 16
    @State private var radius: Double = 12
    @State private var family: String? = "system"
    @State private var largerIcons = false
    @State private var name: TextBuffer = "Guava Studio"
    @State private var saved = 0

    var body: some View {
        ThemeReader { base in
            Box(direction: .column, alignItems: .stretch, spacing: 24) {
                StorySection("Application design system", "Change the application tokens here. The preview inherits a local theme; the surrounding gallery keeps its own theme.") {
                    Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 16) {
                        Select(selection: $family, options: [SelectOption(value: "system", label: "System UI"),
                            SelectOption(value: "Helvetica Neue", label: "Helvetica Neue"), SelectOption(value: "Menlo", label: "Menlo")])
                            .frame(width: 180).debugName("theme-family")
                        Column(alignment: .leading, spacing: 6) {
                            Text("Body · \(Int(bodySize)) pt").font(.caption)
                            Slider(value: $bodySize, range: 12...24, step: 1).frame(width: 180).debugName("theme-body-size")
                        }
                        Column(alignment: .leading, spacing: 6) {
                            Text("Radius · \(Int(radius)) pt").font(.caption)
                            Slider(value: $radius, range: 0...24, step: 1).frame(width: 150).debugName("theme-radius")
                        }
                        Row(alignment: .center, spacing: 8) { Checkbox(isOn: $largerIcons).debugName("theme-larger-icons"); Text("Larger icons").font(.label) }
                    }
                    preview.theme(configured(base))
                }
                StorySection("Typography & fallback", "Semantic roles, explicit points and custom text-style tokens share the same font pipeline. Use Text in the gallery toolbar to check 125–200% scaling.") {
                    Text("Dashboard").font(.display)
                    Text("The quick brown fox · AV fi fl 0123456789").font(.body)
                    Text("Émile · 中文 · 🙂 👩🏽‍💻 🇨🇳 ❤️").font(.headline)
                    Text("Red 🙂 👩🏽‍💻 · color glyphs preserve their own palette").font(.body).foregroundColor(.error)
                    Text("半透明 ❤️ 🇨🇳").font(.headline).opacity(0.5)
                    Text("let value = 42").font(.mono)
                    Text("A 19 pt application style").textStyle(.init(font: .system(size: 19, weight: .medium), lineHeight: 29))
                    Row(alignment: .center, spacing: 20) {
                        Icon(UIIcons.File.folder, size: .small)
                        Icon(UIIcons.File.folder, size: .medium)
                        Icon(UIIcons.File.folder, size: .large)
                        Icon(UIIcons.File.folder, size: 31)
                        Text("Small · medium · large · explicit 31 pt").font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                }
            }
        }
    }

    private func configured(_ base: Theme) -> Theme {
        var theme = base
        theme.typography.family = family == "system" ? nil : family
        theme.typography.body = .init(font: .system(size: Float(bodySize)), lineHeight: Float(bodySize) * 1.45)
        theme.radius.md = Float(radius)
        theme.icons.medium = largerIcons ? 24 : 16
        theme.extensions[EditorialTokens.self].cardInset = largerIcons ? 28 : 20
        return theme
    }

    private var preview: some View {
        ThemeReader { theme in
            Box(direction: .column, alignItems: .stretch, spacing: theme.spacing.xl) {
                Row(alignment: .center, spacing: 12) {
                    Icon(UIIcons.File.folder)
                    Text("Project settings").font(.headline)
                    Spacer()
                    Badge("Local theme", tone: .info)
                }
                Text("A body role belongs to your application. GuavaUI supplies a default, and your design system sets the family, size and line height.")
                TextField("Project name", text: $name).debugName("theme-preview-input")
                Row(alignment: .center, spacing: 12) {
                    Text("\(saved)").font(SemanticFontRef { $0.extensions[EditorialTokens.self].figure })
                    Text("changes saved").font(.caption).foregroundColor(.onSurfaceMuted)
                    Spacer()
                    Button("Save changes") { saved += 1 }.debugName("theme-preview-save")
                }
            }.padding(ThemeMetric { $0.extensions[EditorialTokens.self].cardInset })
                .background(.background).cornerRadius(.controlRadius).border(.border, width: 1)
        }
    }
}
