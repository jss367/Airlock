import AppKit
import SwiftUI

struct WorkspaceOverviewContent: View {
    @ObservedObject var state: WorkspaceOverviewState
    let width: CGFloat
    let onActivate: @MainActor (WorkspaceOverviewTarget) -> Void
    @State private var isVisible: Bool = false

    private var tileWidth: CGFloat {
        WorkspaceOverviewLayout.tileWidth(availableWidth: width, columns: state.gridColumns)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                workspaceBar
                    .padding(.top, 40)
                windowGrid
                Text("←  → workspaces     ↓ or Tab windows     Return open     Esc close")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                    .accessibilityLabel("Left and Right select a workspace. Down or Tab moves into its windows. Return opens the selection. Escape closes.")
            }
            // Fade only: scaling the scroll views while they appear leaves their content offset
            .opacity(isVisible ? 1.0 : 0.0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                isVisible = true
            }
        }
    }

    // MARK: Workspace bar

    private var workspaceBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(state.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        WorkspaceCard(
                            workspace: workspace,
                            thumbnails: state.thumbnails,
                            isSelected: index == state.selectedWorkspaceIndex && state.selectedWindowIndex == nil,
                            action: { onActivate(.workspace(workspace.name)) },
                        )
                        .id(workspace.id)
                    }
                }
                .padding(.horizontal, WorkspaceOverviewLayout.horizontalPadding)
                .padding(.vertical, 4) // room for the selection ring
                .frame(minWidth: width) // center the bar when it's narrower than the screen
            }
            .task {
                if let workspace = state.selectedWorkspace { proxy.scrollTo(workspace.id, anchor: .center) }
            }
            .onChange(of: state.selectedWorkspaceIndex) {
                guard let workspace = state.selectedWorkspace else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(workspace.id, anchor: .center) }
            }
        }
    }

    // MARK: Window grid

    private var windowGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(state.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        WorkspaceSection(
                            workspace: workspace,
                            thumbnails: state.thumbnails,
                            columns: state.gridColumns,
                            tileWidth: tileWidth,
                            headerId: sectionId(workspace),
                            isSelected: index == state.selectedWorkspaceIndex,
                            selectedWindowIndex: index == state.selectedWorkspaceIndex ? state.selectedWindowIndex : nil,
                            onActivate: onActivate,
                        )
                    }
                }
                .padding(.horizontal, WorkspaceOverviewLayout.horizontalPadding)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The focused workspace may be far down the list. Its position is only known after the first layout
            .task { scrollToSelection(proxy) }
            .onChange(of: state.selectedWorkspaceIndex) {
                withAnimation(.easeInOut(duration: 0.15)) { scrollToSelection(proxy) }
            }
            .onChange(of: state.selectedWindowIndex) {
                withAnimation(.easeInOut(duration: 0.15)) { scrollToSelection(proxy) }
            }
        }
    }

    private func sectionId(_ workspace: OverviewWorkspace) -> String { "section-" + workspace.name }

    /// Bring the selected workspace's windows to the top, or the selected window into view
    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let window = state.selectedWindow {
            proxy.scrollTo(window.id)
        } else if let workspace = state.selectedWorkspace {
            proxy.scrollTo(sectionId(workspace), anchor: .top)
        }
    }
}

// MARK: - Selection

/// The one selection treatment, shared by cards and tiles: an accent ring. Hovering only lightens the background
private struct OverviewHighlight: View {
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape
            .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(isHovered ? 0.14 : 0.05))
            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0))
    }
}

// MARK: - Workspace card

private struct WorkspaceCard: View {
    let workspace: OverviewWorkspace
    let thumbnails: [UInt32: CGImage]
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                WorkspaceMiniature(workspace: workspace, thumbnails: thumbnails)
                    .frame(
                        width: WorkspaceOverviewLayout.cardThumbnailSize.width,
                        height: WorkspaceOverviewLayout.cardThumbnailSize.height,
                    )

                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if workspace.isFocused {
                        // Quieter than the selection ring: where the user is, not where Return goes
                        Text("Current")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.12)))
                    }
                }
                .frame(maxWidth: WorkspaceOverviewLayout.cardThumbnailSize.width)
            }
            .padding(10)
            .background(OverviewHighlight(isSelected: isSelected, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }

    private var accessibilityLabel: String {
        let count = workspace.windows.count
        let windows = count == 0 ? "no windows" : count == 1 ? "1 window" : "\(count) windows"
        return "Workspace \(workspace.name), \(windows)" + (workspace.isFocused ? ", current workspace" : "")
    }
}

/// The workspace's windows laid out as they are on its monitor
private struct WorkspaceMiniature: View {
    let workspace: OverviewWorkspace
    let thumbnails: [UInt32: CGImage]

    var body: some View {
        // Back to front, so the windows in front are drawn last
        let placed = workspace.windows.filter { $0.unitFrame != nil }.sorted { $0.stackingOrder > $1.stackingOrder }
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
            if workspace.windows.isEmpty {
                Text("Empty")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if placed.isEmpty {
                // macOS didn't report where the windows are
                HStack(spacing: 6) {
                    ForEach(workspace.windows.prefix(4)) { window in
                        AppIcon(icon: window.icon, size: 28)
                    }
                }
            } else {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        ForEach(placed) { window in
                            let frame = window.unitFrame ?? .zero
                            MiniatureWindow(window: window, thumbnail: thumbnails[window.id])
                                .frame(
                                    width: max(1, frame.width * geometry.size.width),
                                    height: max(1, frame.height * geometry.size.height),
                                )
                                .offset(x: frame.minX * geometry.size.width, y: frame.minY * geometry.size.height)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
                .aspectRatio(workspace.monitorAspectRatio, contentMode: .fit)
                .clipped()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct MiniatureWindow: View {
    let window: OverviewWindow
    let thumbnail: CGImage?

    var body: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 2)
                .resizable()
        } else {
            // Not captured yet, or screen recording isn't allowed
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.16))
                .overlay(AppIcon(icon: window.icon, size: 20))
                .padding(1)
        }
    }
}

// MARK: - Window grid

private struct WorkspaceSection: View {
    let workspace: OverviewWorkspace
    let thumbnails: [UInt32: CGImage]
    let columns: Int
    let tileWidth: CGFloat
    /// What the grid scrolls to when the workspace is selected
    let headerId: String
    let isSelected: Bool
    let selectedWindowIndex: Int?
    let onActivate: @MainActor (WorkspaceOverviewTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(workspace.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("Workspace \(workspace.name)")
                .id(headerId)

            if workspace.windows.isEmpty {
                Text("No windows")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            ForEach(Array(stride(from: 0, to: workspace.windows.count, by: columns)), id: \.self) { rowStart in
                HStack(alignment: .top, spacing: WorkspaceOverviewLayout.tileSpacing) {
                    ForEach(rowStart ..< min(rowStart + columns, workspace.windows.count), id: \.self) { index in
                        let window = workspace.windows[index]
                        WindowTile(
                            window: window,
                            workspaceName: workspace.name,
                            thumbnail: thumbnails[window.id],
                            width: tileWidth,
                            isSelected: index == selectedWindowIndex,
                            action: { onActivate(.window(window.id)) },
                        )
                        .id(window.id)
                    }
                }
            }
        }
    }
}

private struct WindowTile: View {
    let window: OverviewWindow
    let workspaceName: String
    let thumbnail: CGImage?
    let width: CGFloat
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let contentWidth = width - 2 * WorkspaceOverviewLayout.tilePadding
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    } else {
                        // Not captured yet, or screen recording isn't allowed
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                        AppIcon(icon: window.icon, size: 56)
                    }
                }
                .frame(width: contentWidth, height: (contentWidth * 0.625).rounded())

                HStack(spacing: 6) {
                    AppIcon(icon: window.icon, size: 16)
                    Text(window.displayTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: contentWidth)
            }
            .padding(WorkspaceOverviewLayout.tilePadding)
            .background(OverviewHighlight(isSelected: isSelected, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title.isEmpty ? window.appName : "\(window.appName), \(window.title)")
        .accessibilityValue("Workspace \(workspaceName)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

private struct AppIcon: View {
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        Image(nsImage: icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
