import GuavaUI
import GuavaUIRuntime

struct ButtonStory: View {
    let options: GalleryOptions
    @State private var clicks = 0
    @State private var selected = false
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Variants", "Visual treatments communicate action priority.") {
                Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 10) {
                    Button("Primary", isEnabled: options.isEnabled) { clicks += 1 }.debugName("gallery-primary-button")
                    Button("Secondary", isEnabled: options.isEnabled) { clicks += 1 }.buttonStyle(.secondary)
                    Button("Danger", isEnabled: options.isEnabled) { clicks += 1 }.buttonStyle(.destructive)
                    Button("Warning", isEnabled: options.isEnabled) { clicks += 1 }.buttonStyle(.warning)
                    Button("Success", isEnabled: options.isEnabled) { clicks += 1 }.buttonStyle(.success)
                    Button("Info", isEnabled: options.isEnabled) { clicks += 1 }.buttonStyle(.info)
                    Button("Ghost", isEnabled: options.isEnabled) { clicks += 1 }.buttonStyle(.ghost)
                }
            }
            StorySection("Icons & tooltips", "Labels can include real bundled icons. Hover to inspect the tooltip.") {
                Row(alignment: .center, spacing: 12) {
                    Button(isEnabled: options.isEnabled, tooltip: "Confirm changes", action: { clicks += 1 }) {
                        Row(alignment: .center, spacing: 6) { Icon(UIIcons.Action.check, size: 14); Text("Confirm") }
                    }
                    Button(icon: .resource(UIIcons.Action.x), isEnabled: options.isEnabled, tooltip: "Close") { clicks += 1 }.buttonStyle(.secondary).debugName("gallery-icon-button")
                    Button(isEnabled: options.isEnabled, action: { clicks += 1 }) {
                        Row(alignment: .center, spacing: 6) { Text("Custom content"); Icon(UIIcons.Navigation.chevronDown, size: 12) }
                    }.buttonStyle(.secondary)
                }
            }
            StorySection("States", "Loading blocks duplicate activation; selected and disabled states remain distinguishable.") {
                Row(alignment: .center, spacing: 12) {
                    Button("Installing…", isLoading: true) { clicks += 1 }
                    Button("Disabled", isEnabled: false) { clicks += 1 }.buttonStyle(.secondary)
                    Button("\(selected ? "Selected" : "Select me")", isEnabled: options.isEnabled, isSelected: selected) { selected.toggle() }.buttonStyle(.toggle)
                    Text("Actions: \(clicks)").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }
            StorySection("Sizes", "The same control responds to the shared density provider.") {
                Row(alignment: .center, spacing: 12) {
                    for size in ControlSize.allCases {
                        AnyView(Button(String(describing: size).capitalized, isEnabled: options.isEnabled) { clicks += 1 }.controlSize(size))
                    }
                }
            }
        }
    }
}

struct CheckboxStory: View {
    let options: GalleryOptions
    @State private var checked = false
    @State private var mixed: CheckboxState = .mixed
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Selection", "Tab focuses the checkbox; Space and Return activate it. Dragging outside cancels activation.") {
                Row(alignment: .center, spacing: 10) { Checkbox(isOn: $checked, isEnabled: options.isEnabled); Text("Accept the terms") }
                Row(alignment: .center, spacing: 10) { Checkbox(state: $mixed, isEnabled: options.isEnabled); Text("Partially selected collection: \(String(describing: mixed))") }
                Button("Reset mixed state") { mixed = .mixed }.buttonStyle(.ghost)
            }
            StorySection("Disabled", "Disabled controls are omitted from keyboard focus traversal.") {
                Row(alignment: .center, spacing: 16) {
                    Checkbox(isOn: .constant(false), isEnabled: false)
                    Checkbox(isOn: .constant(true), isEnabled: false)
                    Checkbox(state: .constant(.mixed), isEnabled: false)
                    Text("Unchecked · Checked · Mixed").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }
        }
    }
}

struct ToggleStory: View {
    let options: GalleryOptions
    @State private var notifications = true
    @State private var telemetry = false
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Settings", "A switch owns activation and animation; the application owns the value.") {
                Row(alignment: .center, spacing: 12) { Toggle(isOn: $notifications, isEnabled: options.isEnabled); Text("Notifications: \(notifications ? "On" : "Off")") }
                Row(alignment: .center, spacing: 12) { Toggle(isOn: $telemetry, isEnabled: options.isEnabled); Text("Usage analytics: \(telemetry ? "On" : "Off")") }
            }
            StorySection("Disabled", "The value stays visible while the setting cannot be changed.") {
                Row(alignment: .center, spacing: 16) { Toggle(isOn: .constant(true), isEnabled: false); Toggle(isOn: .constant(false), isEnabled: false) }
            }
        }
    }
}

struct TextFieldStory: View {
    let options: GalleryOptions
    @State private var name: TextBuffer = "GuavaUI"
    @State private var password: TextBuffer = "correct horse"
    @State private var url: TextBuffer = "example.com"
    @State private var limited: TextBuffer = "Hello"
    @State private var unicode: TextBuffer = "A👩🏽‍💻中🙂B"
    @State private var status = "Press Return to submit"
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Input & clear", "The cursor, selection and IME composition survive recomposition.") {
                TextField("Your name", text: $name) { input in
                    input.behavior.disabled = !options.isEnabled
                    input.behavior.clearable = true
                    input.events.onSubmit = { status = "Submitted: \(name.stringValue)" }
                }.frame(width: 360)
                Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
            }
            StorySection("Password & read-only", "Password fields suppress copying the secret; read-only fields still permit selection.") {
                TextField("Password", text: $password) { $0.behavior.secure = true; $0.behavior.disabled = !options.isEnabled }.frame(width: 360)
                TextField("", text: .constant("Read-only value")) { $0.behavior.readOnly = true }.frame(width: 360)
                TextField("Disabled", text: .constant("Unavailable")) { $0.behavior.disabled = true }.frame(width: 360)
            }
            StorySection("Decorations & limits", "Decoration and behavior are independent typed groups.") {
                TextField("Domain", text: $url) { $0.decoration.prepend = "https://"; $0.decoration.append = "/"; $0.behavior.disabled = !options.isEnabled }.frame(width: 420)
                TextField("Up to 20 characters", text: $limited) { $0.behavior.maxLength = 20; $0.decoration.showWordLimit = true; $0.behavior.disabled = !options.isEnabled }.frame(width: 360)
            }
            StorySection("Unicode editing", "Arrow keys, selection and deletion treat a joined emoji as one character. Try replacing the selection, then undoing it.") {
                TextField("Names and emoji", text: $unicode) { $0.behavior.disabled = !options.isEnabled }.frame(width: 420)
                Text("\(unicode.characterCount) characters · \(unicode.utf8Length) UTF-8 bytes").font(.caption).foregroundColor(.onSurfaceMuted)
            }
        }
    }
}

struct TextAreaStory: View {
    let options: GalleryOptions
    @State private var text: TextBuffer = "Multiline text wraps within the field.\nTry editing, selecting, pasting and scrolling.\nThe resize grip belongs to the surrounding container."
    var body: some View {
        StorySection("Resizable text area", "The container controls height; the text field controls its own scrolling.") {
            ResizableTextArea("Write a note…", text: $text, minHeight: 90, maxHeight: 320, disabled: !options.isEnabled)
                .frame(width: 520)
            Text("\(text.characterCount) characters").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct NumberFieldStory: View {
    let options: GalleryOptions
    @State private var amount: Float = 3.14
    var body: some View {
        StorySection("Numeric editing", "Invalid drafts revert on blur. Arrow keys step; Shift multiplies the step and Option divides it.") {
            NumberField(value: $amount, isEnabled: options.isEnabled, minValue: 0, maxValue: 10, step: 0.25, showsStepper: true).frame(width: 220)
            NumberField(value: .constant(0), isEnabled: options.isEnabled, mixedValueLabel: "Mixed value").frame(width: 220)
            NumberField(value: .constant(42), isEnabled: false).frame(width: 220)
            Text("Committed value: \(amount)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct Vec3Story: View {
    let options: GalleryOptions
    @State private var x: Float = 1
    @State private var y: Float = 2
    @State private var z: Float = 3
    var body: some View {
        StorySection("Transform", "Each axis shares numeric validation. Narrow rows remain shrinkable.") {
            Vec3Field(x: $x, y: $y, z: $z, isEnabled: options.isEnabled, step: 0.1).frame(width: 420)
            Vec3Field(x: $x, y: $y, z: $z, isEnabled: options.isEnabled, mixedAxes: ["x", "z"]).frame(width: 300)
            Text("Position: \(x), \(y), \(z)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct ColorStory: View {
    let options: GalleryOptions
    @State private var color = Color(red: 88, green: 126, blue: 231)
    var body: some View {
        StorySection("Color picker", "Open the swatch to edit RGB, alpha and hexadecimal values.") {
            ColorField(color: $color, isEnabled: options.isEnabled, showsInlineValues: true)
            ColorField(color: $color, isEnabled: options.isEnabled, showAlpha: false)
            Box {}.frame(width: 200, height: 60).background(color).cornerRadius(8)
        }
    }
}

struct SelectStory: View {
    let options: GalleryOptions
    @State private var quality = "high"
    var body: some View {
        StorySection("Typed options", "Open with Space or Return, move with arrows, select with Return and dismiss with Escape.") {
            Select(selection: $quality, options: [
                SelectOption(value: "fast", label: "Fast"), SelectOption(value: "balanced", label: "Balanced"),
                SelectOption(value: "high", label: "High quality · International collaboration and workspace permissions 👩🏽‍💻"),
                SelectOption(value: "offline", label: "Unavailable", isEnabled: false)
            ], isEnabled: options.isEnabled).frame(maxWidth: 360)
            Text("Selected: \(quality)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct JsonStory: View {
    let options: GalleryOptions
    @State private var json: TextBuffer = "{\"name\":\"Guava\",\"enabled\":true,\"version\":1}"
    var body: some View {
        StorySection("Structured input", "Format valid JSON, try a syntax error, then revert to the original value.") {
            JsonField(text: $json, isEnabled: options.isEnabled).frame(width: 520)
        }
    }
}

struct LinkStory: View {
    let options: GalleryOptions
    @State private var lastOpened = "none"
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Inside body copy", "A link keeps the surrounding type size and stays in the reading flow; the underline is what makes it findable before the pointer arrives.") {
                Row(alignment: .center, spacing: 2) {
                    Text("Read the")
                    Link("style guide", isEnabled: options.isEnabled) { lastOpened = "style guide" }
                    Text("and the")
                    Link("contribution policy", isEnabled: options.isEnabled, configure: { $0.isExternal = true }) { lastOpened = "contribution policy" }
                    Text("before opening a pull request.")
                }
                Text("Last opened: \(lastOpened)").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            StorySection("Underline on hover", "Dense surfaces keep the text clean: the rule appears on hover and on keyboard focus, so keyboard users are not left guessing.") {
                Row(alignment: .center, spacing: 16) {
                    Link("Reset layout", isEnabled: options.isEnabled, configure: { $0.underline = .hover }) { lastOpened = "reset layout" }
                    Link("Copy build log", isEnabled: options.isEnabled, configure: { $0.underline = .hover; $0.icon = UIIcons.Action.copy }) { lastOpened = "copy build log" }
                    Link("Unavailable", isEnabled: false, configure: { $0.underline = .hover }) { }
                }
            }
            StorySection("Never underlined", "Colour alone carries the affordance — only defensible where the surrounding text is clearly not interactive.") {
                Link("Skip onboarding", isEnabled: options.isEnabled, configure: { $0.underline = .never }) { lastOpened = "skip onboarding" }
            }
        }
    }
}

struct SearchFieldStory: View {
    let options: GalleryOptions
    @State private var query = TextBuffer("")
    @State private var last = "None"

    var body: some View {
        StorySection("Search input", "Type to filter suggestions. Arrow keys move the highlight, Return selects it, Escape clears, and the field keeps the regular TextField chrome and clear action.") {
            SearchField(
                text: $query,
                placeholder: "Search components",
                suggestions: ["Camera", "Canvas", "Counter", "Timeline", "Toolbar"],
                isEnabled: options.isEnabled,
                onSubmit: { last = "submitted “\($0)”" },
                onSuggestionSelected: { last = "selected “\($0)”" }
            ).frame(maxWidth: 420)
            Text("Query: \(query.stringValue) · \(last)")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct MenuButtonStory: View {
    let options: GalleryOptions
    @State private var last = "None"

    var body: some View {
        StorySection("Button-triggered menu", "The trigger keeps regular button chrome and expanded semantics. The menu closes on action selection, Escape or an outside click.") {
            Row(alignment: .center, spacing: 12) {
                MenuButton("Options", entries: [
                    .item(MenuItem(id: "rename", title: "Rename") { last = "Rename" }),
                    .item(MenuItem(id: "duplicate", title: "Duplicate") { last = "Duplicate" }),
                    .separator("separator"),
                    .item(MenuItem(id: "delete", title: "Delete", role: .destructive) { last = "Delete" }),
                ], isEnabled: options.isEnabled, width: 200)
                MenuButton("Disabled", entries: [.item(MenuItem(id: "none", title: "Unavailable") {})],
                           isEnabled: false, width: 200)
            }
            Text("Last action: \(last)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct RangeSliderStory: View {
    let options: GalleryOptions
    @State private var values: ClosedRange<Double> = 20...80

    var body: some View {
        StorySection("Range selection", "Click near a thumb and drag it. Arrow keys move the active thumb, Home/End jump to the bounds, and the minimum span prevents crossing.") {
            RangeSlider(values: $values, in: 0...100, step: 1, minimumSpan: 10,
                        isEnabled: options.isEnabled)
                .frame(maxWidth: 420)
            Text("Selected: \(Int(values.lowerBound)) – \(Int(values.upperBound))")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct SplitButtonStory: View {
    let options: GalleryOptions
    @State private var last = "None"

    var body: some View {
        StorySection("Primary + menu", "The left zone runs the default action; the arrow opens the same menu used by MenuButton. Both zones have independent hit areas and disabled behavior.") {
            SplitButton("Save", entries: [
                .item(MenuItem(id: "saveAs", title: "Save as…") { last = "Save as" }),
                .item(MenuItem(id: "export", title: "Export") { last = "Export" }),
                .separator("sep"),
                .item(MenuItem(id: "discard", title: "Discard", role: .destructive) { last = "Discard" }),
            ], isEnabled: options.isEnabled, menuWidth: 200, action: { last = "Save" })
            Text("Last action: \(last)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
