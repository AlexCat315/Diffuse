import GuavaUICompose
import GuavaUIRuntime

struct HoverCardStory: View {
    let options: GalleryOptions
    @State private var following = false
    @State private var profileOpen = false
    private var profile: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 10) {
            Row(alignment: .center, spacing: 10) {
                Avatar("Ada Lovelace") { $0.diameter = 40 }
                Column(alignment: .leading, spacing: 3) {
                    Text("Ada Lovelace").font(.bodyStrong)
                    Text("Analytical Engine · maintainer").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }
            Text("Contributor since 1843. Open the profile with a click or keyboard for the same actions.")
                .font(.caption).foregroundColor(.onSurfaceMuted)
            Button(following ? "Unfollow" : "Follow", isEnabled: options.isEnabled) { following.toggle() }
                .buttonStyle(.secondary).debugName("hover-follow")
        }
    }
    var body: some View {
        StorySection("Interactive detail", "Move from the name into the card and use Follow. Escape or clicking outside dismisses it. Open profile offers the same information and action from the keyboard.") {
            Column(alignment: .leading, spacing: 12) {
                HoverCard(width: 340, configure: { $0.isEnabled = options.isEnabled }, label: {
                    Text("@ada").font(.bodyStrong).foregroundColor(.accent)
                        .debugName("hover-profile-trigger")
                }) {
                    profile
                }
                Popover(isPresented: $profileOpen, isEnabled: options.isEnabled, width: 360, label: {
                    Text("Open profile").font(.label)
                }, content: { profile.padding(16).background(.surfaceFloating).cornerRadius(8) })
                Text(following ? "Following Ada" : "Not following Ada").font(.caption).foregroundColor(.onSurfaceMuted)
                HoverCard(width: 300, configure: { $0.isEnabled = options.isEnabled }, label: {
                    Row(alignment: .center, spacing: 6) {
                        Icon(UIIcons.Editor.box, size: 14, color: .onSurfaceMuted)
                        Text("MeshRenderer").font(.bodyStrong)
                    }
                }) {
                    Column(alignment: .leading, spacing: 6) {
                        Text("Renders a mesh with a material").font(.body)
                        Text("Costs one draw call per submesh.").font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                }
            }
        }
    }
}
