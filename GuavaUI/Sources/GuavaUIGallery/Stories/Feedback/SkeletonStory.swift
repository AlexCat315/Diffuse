import GuavaUICompose
import GuavaUIRuntime

struct SkeletonStory: View {
    let options: GalleryOptions
    @State private var loading = true
    @State private var animated = true
    @State private var reducedMotion = false
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Loading a profile", "The placeholder preserves the content layout. Switch to data, restart loading, or freeze the pulse to inspect its shapes.") {
                Row(alignment: .center, spacing: 12) {
                    Button(loading ? "Show content" : "Load again", isEnabled: options.isEnabled) { loading.toggle() }
                        .debugName("skeleton-toggle")
                    Checkbox(isOn: $animated, isEnabled: options.isEnabled).accessibilityLabel("Animate placeholders")
                    Text("Animate").font(.caption)
                    Checkbox(isOn: $reducedMotion, isEnabled: options.isEnabled).accessibilityLabel("Reduce motion")
                    Text("Reduce motion").font(.caption)
                }
                Row(alignment: .center, spacing: 16) {
                    if loading {
                        Skeleton { $0.appearance.shape = .circle; $0.appearance.height = 48; $0.motion.isAnimated = animated }
                    } else { Avatar("Ada Lovelace") { $0.diameter = 48 } }
                    Box(direction: .column, alignItems: .stretch, spacing: 8) {
                        if loading {
                            Skeleton { $0.appearance.height = 18; $0.motion.isAnimated = animated }.frame(width: 180)
                            Skeleton { $0.appearance.height = 14; $0.appearance.isSecondary = true; $0.motion.isAnimated = animated }.frame(width: 260)
                        } else {
                            Text("Ada Lovelace").font(.bodyStrong)
                            Text("Analytical Engine · Maintainer").font(.caption).foregroundColor(.onSurfaceMuted)
                        }
                    }
                }.frame(height: 64).reducedMotion(reducedMotion).debugName("skeleton-profile")
            }
            StorySection("Content placeholders", "Rectangles, rounded panels and circular avatars share a node-owned clock. Decorative shapes stay out of the accessibility tree.") {
                Skeleton { $0.appearance.height = 100; $0.appearance.shape = .rectangle(cornerRadius: 12); $0.motion.isAnimated = animated }
                    .frame(width: 380)
                Skeleton { $0.appearance.height = 16; $0.motion.isAnimated = animated }.frame(width: 340)
                Skeleton { $0.appearance.height = 16; $0.appearance.isSecondary = true; $0.motion.isAnimated = animated }.frame(width: 260)
            }.reducedMotion(reducedMotion)
        }
    }
}
