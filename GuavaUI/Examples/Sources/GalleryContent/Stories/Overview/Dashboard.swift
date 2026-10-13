import GuavaUI
import GuavaUIRuntime

/// Authored sample values are deterministic. Actions change real component
/// state; the gallery reset recreates this story and restores the initial data.
struct IntroductionStory: View {
    let options: GalleryOptions
    @State private var period: String? = "today"
    @State private var isPaused = false
    @State private var progress = 0.64
    @State private var completed = 8
    @State private var activity = "Asset import started · just now"

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 20) {
            Row(alignment: .center, spacing: 12) {
                Column(alignment: .leading, spacing: 4) {
                    Text("Your workspace, at a glance").font(.headline)
                    Text("Sample project · local session").font(.body).foregroundColor(.onSurfaceMuted)
                }
                Spacer()
                ButtonGroup([ButtonGroupItem("today", "Today"), ButtonGroupItem("week", "This week")], selection: $period, isEnabled: options.isEnabled)
                    .debugName("dashboard-period")
            }
            Box(direction: .row, alignItems: .stretch, wrap: .wrap, spacing: 16) {
                MetricCard(title: "Engine", value: isPaused ? "Paused" : "Ready", unit: "", detail: "Guava Engine · native renderer", history: [], tone: .success)
                MetricCard(title: "Frame time", value: "8.4", unit: "ms", detail: "Sample trace · 119 frames / second", history: [22, 18, 26, 20, 25, 16, 21, 15, 24, 18, 21, 19], tone: .accentSecondary)
                MetricCard(title: "Assets", value: period == "week" ? "1,284" : "248", unit: "", detail: period == "week" ? "Imported this week" : "Imported today", history: [9, 12, 18, 12, 26, 22, 32, 38, 34, 52, 58, 64], tone: .info)
                MetricCard(title: "Completed", value: "\(completed)", unit: "tasks", detail: "All changes saved locally", history: [], tone: .success)
            }
            Box(direction: .row, alignItems: .stretch, wrap: .wrap, spacing: 16) {
                importCard.frame(minWidth: 280).flex(2, shrink: 1, basis: 420)
                activityCard.frame(minWidth: 240).flex(1, shrink: 1, basis: 260)
            }
            DashboardCard {
                Row(alignment: .center, spacing: 12) {
                    Column(alignment: .leading, spacing: 6) {
                        Text("Made from real components").font(.headline)
                        Text("Explore \(GalleryCatalog.entries.count) stories. Switch appearance, change density, use the keyboard, or reset this session.")
                            .font(.body).foregroundColor(.onSurfaceMuted)
                    }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
                    Badge("Light + dark") { $0.tone = .info; $0.showsDot = true }
                }
            }
        }.debugName("dashboard-story")
    }

    private var importCard: some View {
        DashboardCard {
            Row(alignment: .center, spacing: 12) {
                Text("Asset import").font(.headline)
                Spacer()
                Badge(progress >= 1 ? "Complete" : isPaused ? "Paused" : "Running") {
                    $0.tone = progress >= 1 ? .success : isPaused ? .warning : .info
                    $0.showsDot = true
                }
            }
            Row(alignment: .center, spacing: 12) {
                Icon(UIIcons.File.folder, size: 28).foregroundColor(.accent)
                Column(alignment: .leading, spacing: 5) {
                    Text("Environment assets").font(.bodyStrong)
                    Text("Textures, materials and scene geometry").font(.body).foregroundColor(.onSurfaceMuted)
                }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
            }
            ProgressView(value: progress) { $0.height = 6 }.debugName("dashboard-progress")
            Row(alignment: .center, spacing: 10) {
                Text("\(Int(progress * 100))% imported").font(.caption).foregroundColor(.onSurfaceMuted)
                Spacer()
                Button(isPaused ? "Resume" : "Pause", isEnabled: options.isEnabled && progress < 1) {
                    isPaused.toggle()
                    activity = isPaused ? "Asset import paused · just now" : "Asset import resumed · just now"
                }.buttonStyle(.secondary).debugName("dashboard-pause")
                Button(progress >= 1 ? "Import again" : "Advance", isEnabled: options.isEnabled && !isPaused) {
                    if progress >= 1 { progress = 0; activity = "New asset import started · just now" }
                    else {
                        progress = min(1, progress + 0.12)
                        if progress >= 1 { completed += 1; activity = "Asset import completed · just now" }
                        else { activity = "Imported next batch · just now" }
                    }
                }.debugName("dashboard-advance")
            }
        }
    }

    private var activityCard: some View {
        DashboardCard {
            Text("Recent activity").font(.headline)
            activityRow(activity, detail: "Environment assets", tone: .info)
            Divider()
            activityRow("Scene saved", detail: "Main scene · 4 minutes ago", tone: .success)
            Divider()
            activityRow("Shader compiled", detail: "Standard material · 12 minutes ago", tone: .neutral)
        }
    }

    private func activityRow(_ title: String, detail: String, tone: StatusTone) -> some View {
        Row(alignment: .top, spacing: 10) {
            Badge("", tone: tone) { $0.showsDot = true }.accessibilityHidden()
            Column(alignment: .leading, spacing: 5) {
                Text(title).font(.label)
                Text(detail).font(.caption).foregroundColor(.onSurfaceMuted)
            }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
        }
    }
}
