import Testing
@testable import GuavaUICompose
import GuavaUIRuntime

// MARK: - Status tone

@Test("Status tones map to distinct glyphs and stay case-iterable")
func statusToneCatalogue() {
    #expect(StatusTone.allCases.count == 5)
    let glyphs = Set(StatusTone.allCases.map(\.icon.name))
    #expect(glyphs.count == StatusTone.allCases.count)
}

@Test("Solid ink keeps contrast against the tone that fills the surface")
func statusToneInkOnSolid() {
    // The invariant that matters: whatever hue a theme picks for a tone, the
    // ink drawn on top of it has to stay legible. Hard-coding white here is
    // what breaks a light amber warning badge.
    for theme in [Theme.defaultDark, Theme.defaultLight] {
        for tone in StatusTone.allCases {
            let ink = tone.ink(onSolid: theme)
            let fill = tone.color.resolve(theme)
            let inkLuminance = 0.2126 * ink.r + 0.7152 * ink.g + 0.0722 * ink.b
            let fillLuminance = 0.2126 * fill.r + 0.7152 * fill.g + 0.0722 * fill.b
            #expect(abs(inkLuminance - fillLuminance) > 0.3,
                    "\(tone) ink washes out on its own fill")
        }
    }
}

// MARK: - Command palette ranking

@Test("Command palette ranks tighter matches first and disabled entries last")
func commandPaletteRanking() {
    let items = [
        CommandItem("Generate Textures", group: "Tools") {},
        CommandItem("Git Toggle", group: "Tools") {},
        CommandItem("Toggle Theme", group: "View") {},
        CommandItem("Deploy to Device", group: "Build", isEnabled: false) {}
    ]

    // "gt" is a subsequence of both texture and git commands; the one that
    // skips fewer characters wins.
    #expect(CommandPalette.ranked(items, query: "gt").first?.title == "Git Toggle")
    // A prefix beats a mid-string hit.
    #expect(CommandPalette.ranked(items, query: "toggle").first?.title == "Toggle Theme")
    // Disabled commands stay listed — hiding them makes the palette feel
    // broken when the user knows the command exists — but never sort first.
    let forTo = CommandPalette.ranked(items, query: "to").map(\.title)
    #expect(forTo.last == "Deploy to Device")
    #expect(forTo.first != "Deploy to Device")
    // An empty query is the browse state: authored order, nothing dropped.
    #expect(CommandPalette.ranked(items, query: "   ").map(\.title) == items.map(\.title))
}


@Test("Recent commands lead the browse list once and never duplicate groups")
func commandPaletteRecentEntries() {
    let items = [
        CommandItem("Open File", group: "File") {},
        CommandItem("Toggle Theme", group: "View") {},
        CommandItem("Deploy", group: "Build", isEnabled: false) {}
    ]
    let ids = CommandPalette.displayEntries(items: items, recentIDs: ["Toggle Theme", "missing"],
                                             showsRecent: true, limit: 3,
                                             groupsResults: false).map(\.id)
    #expect(ids == ["header:Recent", "item:Toggle Theme", "item:Open File", "item:Deploy"])

    let deduped = CommandPalette.displayEntries(items: items, recentIDs: ["Toggle Theme"],
                                                 showsRecent: true, limit: 1,
                                                 groupsResults: false).map(\.id)
    #expect(deduped == ["header:Recent", "item:Toggle Theme", "item:Open File", "item:Deploy"])

    let disabled = CommandPalette.displayEntries(items: items, recentIDs: ["Deploy"],
                                                  showsRecent: true, limit: 3,
                                                  groupsResults: false).map(\.id)
    #expect(!disabled.contains("header:Recent"))
    #expect(disabled.contains("item:Deploy"))

    let hidden = CommandPalette.displayEntries(items: items, recentIDs: ["Toggle Theme"],
                                                showsRecent: false, limit: 3,
                                                groupsResults: false).map(\.id)
    #expect(hidden == ["item:Open File", "item:Toggle Theme", "item:Deploy"])
}

// MARK: - Progress

@Test("Progress clamps out-of-range values instead of drawing outside the track")
func progressClamps() {
    #expect(ProgressView(value: 2.5).clamped == 1)
    #expect(ProgressView(value: -1).clamped == 0)
    #expect(ProgressView(value: nil).clamped == 0)
    #expect(ProgressView(value: .nan).clamped == 0)
    #expect(ProgressView(value: 0.42).clamped == 0.42)
}

@Test("ProgressCircle keeps a usable ring at every diameter")
func progressCircleThickness() {
    let small = ProgressCircle(value: 0.5, diameter: 16)
    let large = ProgressCircle(value: 0.5, diameter: 64)
    #expect(small.resolvedThickness(for: 16) >= 2)
    #expect(large.resolvedThickness(for: 64) < 64 / 2)
    #expect(small.resolvedThickness(for: 16) < large.resolvedThickness(for: 64))
    // An explicit thickness is honoured but can never swallow the ring.
    let forced = ProgressCircle(value: 0.5, diameter: 20) { $0.thickness = 40 }
    #expect(forced.resolvedThickness(for: 20) == 10)
}

// MARK: - Timeline

@Test("Timeline orders events and hides the trailing connector by default")
func timelineContent() {
    let timeline = Timeline(events: [
        TimelineEvent("Started", tone: .info),
        TimelineEvent("Failed", tone: .danger)
    ])
    #expect(timeline.events.map(\.title) == ["Started", "Failed"])
    #expect(timeline.events.first?.tone == .info)
    #expect(timeline.showsTrailingConnector == false)
    #expect(Timeline(events: []) { $0.showsTrailingConnector = true }.showsTrailingConnector)
}
