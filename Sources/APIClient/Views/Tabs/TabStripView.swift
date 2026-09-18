import SwiftUI
import ApiClientCore

/// 当前项目的请求标签条。
///
/// 直接挂在顶层「项目标签」之下：这里永远只有当前一个项目的标签，
/// 所以不需要项目徽标，也不会有「关掉别的项目正在编辑的东西」这种事。
struct TabStripView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    private var tabIDs: [UUID] { store.visibleSessions.map(\.id) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.space.xs) {
                        ForEach(store.visibleSessions) { session in
                            TabChipView(session: session)
                                .id(session.id)
                                .transition(
                                    .asymmetric(
                                        insertion: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity),
                                        removal: .scale(scale: 0.88, anchor: .leading).combined(with: .opacity)
                                    )
                                )
                        }
                    }
                    .padding(.horizontal, DS.space.md)
                    .padding(.vertical, DS.space.sm)
                }
                .animation(DS.motion.enter, value: tabIDs)
                .onChange(of: store.activeTabID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(DS.motion.select) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            Rectangle()
                .fill(DS.color.hairline)
                .frame(width: 1, height: 16)

            HStack(spacing: DS.space.hair) {
                Button {
                    store.newDraftTab()
                } label: {
                    AppIcon(symbol: "plus", size: 11, weight: .semibold)
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("新建请求标签（⌘T）")

                Menu {
                    Button("关闭当前标签") {
                        if let id = store.activeTabID { TabClosing.close(id, store: store, ui: ui) }
                    }
                    Button("关闭其他标签") {
                        if let id = store.activeTabID { TabClosing.closeOthers(keeping: id, store: store, ui: ui) }
                    }
                    Divider()
                    Button("关闭当前项目的所有标签") {
                        if let id = store.activeProjectID { TabClosing.closeAll(for: id, store: store, ui: ui) }
                    }
                    .disabled(store.activeProjectID == nil || tabIDs.isEmpty)
                    Button("关闭所有项目的标签") { TabClosing.closeAll(store: store, ui: ui) }
                    .disabled(store.sessions.isEmpty)
                } label: {
                    AppIcon(symbol: "ellipsis", size: 11, weight: .semibold)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("标签页操作")
            }
            .padding(.horizontal, DS.space.sm)
        }
        .frame(height: DS.metric.tabStripHeight)
        .background(DS.color.sunken)
    }
}

struct TabChipView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    let session: TabSession

    @State private var isHovering = false

    private var isActive: Bool { store.activeTabID == session.id }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.activateTab(id: session.id)
            } label: {
                HStack(spacing: DS.space.sm) {
                    methodLabel

                    Text(session.displayName)
                        .font(isActive ? DS.font.bodyMedium : DS.font.body)
                        .foregroundStyle(isActive ? DS.color.textPrimary : DS.color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 148, alignment: .leading)
                }
                .padding(.leading, DS.space.md)
                .frame(height: DS.metric.tabHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle(scale: 0.97))

            statusArea
                .padding(.trailing, DS.space.xs)
        }
        .background(shape.fill(background))
        .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
        .shadow(color: isActive ? .black.opacity(0.07) : .clear, radius: 3, y: 1)
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .animation(DS.motion.select, value: isActive)
        .animation(DS.motion.hover, value: isHovering)
        .contextMenu {
            if let requestID = session.requestID {
                let favorited = store.isFavorite(projectID: session.projectID, requestID: requestID)
                Button(favorited ? "取消收藏" : "收藏") {
                    store.toggleFavorite(projectID: session.projectID, requestID: requestID)
                }
                Button("在侧边栏中定位") {
                    store.locateInSidebar(projectID: session.projectID, requestID: requestID)
                }
                Divider()
            }
            Button("关闭") { TabClosing.close(session.id, store: store, ui: ui) }
            Button("关闭其他标签") { TabClosing.closeOthers(keeping: session.id, store: store, ui: ui) }
            Button("关闭右侧标签") { TabClosing.closeToTheRight(of: session.id, store: store, ui: ui) }
            Divider()
            Button("关闭「\(store.activeProject?.name ?? "")」的全部标签") {
                if let id = store.activeProjectID { TabClosing.closeAll(for: id, store: store, ui: ui) }
            }
        }
        .help(session.buffer.url.isEmpty ? session.displayName : session.buffer.url)
    }

    private var methodLabel: some View {
        Text(session.buffer.method.rawValue)
            .font(DS.font.badgeSmall)
            .foregroundStyle(session.buffer.method.tint)
            .frame(width: 30, alignment: .leading)
    }

    /// 右侧固定宽度的状态位：发送中转圈｜未保存圆点｜悬停时变成关闭按钮。
    private var statusArea: some View {
        ZStack {
            if session.isSending {
                SpinnerDot(color: DS.color.brand, size: 10)
            } else if session.isDirty {
                DirtyDot()
            }

            if isHovering, !session.isSending {
                Button {
                    TabClosing.close(session.id, store: store, ui: ui)
                } label: {
                    AppIcon(symbol: "xmark", size: 8, weight: .bold, tint: DS.color.textSecondary)
                }
                .buttonStyle(IconButtonStyle(size: 16))
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                .help("关闭标签")
            }
        }
        .frame(width: 18, height: 18)
    }

    private var background: Color {
        if isActive { return DS.color.elevated }
        return isHovering ? DS.color.rowHover : .clear
    }

    private var borderColor: Color {
        isActive ? DS.color.border : .clear
    }
}
