import Foundation
import GuavaUIRuntime

/// Turns an `AvatarGroup` overflow marker into a button that opens the member
/// list. Rows show each avatar, name and presence; with `onSelect` they become
/// buttons and the popover closes after a selection.
public struct AvatarMemberList {
    public enum Scope: Sendable, Hashable {
        /// Every member, so the list is the full roster.
        case all
        /// Only the members hidden behind the overflow marker.
        case remaining
    }
    public var title = "Members"
    public var scope: Scope = .all
    public var onSelect: ((Avatar) -> Void)?
    public init() {}
}

/// Overflow marker that owns the popover's session-only presentation state.
struct AvatarMemberListTrigger: View {
    let marker: AvatarOverflowMarker
    let members: [Avatar]
    let list: AvatarMemberList
    @State private var presented = false

    var body: some View {
        var popover = Popover(isPresented: $presented, width: 260, placement: .bottomLeading,
                              overflow: .flip, label: { marker }) {
            AvatarMemberListContent(title: list.title, members: members, onSelect: list.onSelect.map { select in
                { member in presented = false; select(member) }
            })
        }
        popover.triggerDescription = PopoverTriggerDescription(label: marker.accessibilityLabel, help: marker.names)
        return popover.cornerRadius(marker.diameter / 2)
    }
}

struct AvatarMemberListContent: View {
    let title: String
    let members: [Avatar]
    let onSelect: ((Avatar) -> Void)?

    var body: some View {
        Column(alignment: .leading, spacing: 2) {
            Text(title).truncatingTail().font(.bodyStrong)
                .padding(horizontal: 8, vertical: 4)
                .accessibility { $0.role = .heading; $0.label = title }
            for (index, member) in members.enumerated() {
                AnyView(row(member).id(member.id ?? "member-\(index)"))
            }
        }
        .padding(4)
        .accessibility { $0.role = .list; $0.label = title; $0.value = "\(members.count) members" }
    }

    private func row(_ member: Avatar) -> some View {
        let content = AvatarMemberRow(member: member)
        guard let onSelect else { return AnyView(content.padding(horizontal: 8, vertical: 4)) }
        return AnyView(Button(action: { onSelect(member) }) { content }
            .buttonStyle(GhostButtonStyle())
            .compositionLocal(ActionControlAccessibility.label, member.name.isEmpty ? "Anonymous user" : member.name)
            .compositionLocal(ActionControlAccessibility.value, member.statusText))
    }
}

/// One roster line. The avatar copy keeps source, colors and status; only the
/// diameter is unified so long rosters stay compact.
struct AvatarMemberRow: View {
    let member: Avatar
    var body: some View {
        var avatar = member
        avatar.appearance.diameter = 28
        let name = member.name.isEmpty ? "Anonymous user" : member.name
        return Row(alignment: .center, spacing: 10) {
            avatar.flex(0, shrink: 0)
            Column(alignment: .leading, spacing: 0) {
                Text(name).truncatingTail()
                if !member.statusText.isEmpty {
                    Text(member.statusText).truncatingTail().font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }.flex(1, shrink: 1).frame(minWidth: 0)
        }
        .frame(minHeight: 44)
        .accessibility { $0.role = .listItem; $0.label = name; $0.value = member.statusText; $0.combinesChildren = true }
    }
}
