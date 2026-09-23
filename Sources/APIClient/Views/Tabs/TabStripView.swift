import SwiftUI
import ApiClientCore

/// 当前项目的请求标签条。
///
/// 项目切换由顶层 `ProjectTabBar` 负责；这里不再混入其他项目的标签，
/// 也不再用项目名前缀区分不同项目。
struct TabStripView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    private var orderedSessions: [TabSession] { store.allOrderedSessions }
    private var tabIDs: [UUID] { orderedSessions.map(\.id) }


    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.space.sm) {
                        ForEach(orderedSessions) { session in
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
                    // 显式贴底：横向 ScrollView 不会自动把内容压到底边，
                    // 不锁 alignment 就会在标签和下面的内容之间留出一道缝。
                    .frame(height: DS.metric.tabStripHeight, alignment: .bottom)
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
            .frame(height: DS.metric.tabStripHeight, alignment: .bottom)
            .padding(.bottom, DS.space.xs)
        }
        .frame(height: DS.metric.tabStripHeight)
        // 比激活标签与下方地址栏都暗一档：颜色差本身就是分隔，不必再画一条线。
        // 用 sunken 而不是 canvas：深色模式下 canvas 和 surface 几乎同色，
        // 激活标签就浮不出来了。
        .background(DS.color.sunken)
    }
}

struct TabChipView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    let session: TabSession

    @State private var isHovering = false

    private var isActive: Bool { store.activeTabID == session.id }

    /// 只圆上面两个角：下边要和内容区连成一体，圆角会露出一道缝。
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: DS.radius.md,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: DS.radius.md,
            style: .continuous
        )
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
            // 名称原先常驻在编辑区一条元信息栏里占着输入框，改成按需重命名。
            .simultaneousGesture(TapGesture(count: 2).onEnded { promptRename() })

            statusArea
                .padding(.trailing, DS.space.xs)
        }
        .background(shape.fill(background))
        .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
        // strokeBorder 会把底边也描上，激活标签就被“封口”了。
        // 用同色细线盖掉底边，标签与下面的地址栏连成一块。
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(DS.color.surface)
                    .frame(height: 1)
            }
        }
        // y 取负：阴影往上飘，别在标签与内容的接缝处压出一道暗边。
        .shadow(color: isActive ? .black.opacity(0.10) : .clear, radius: 3, y: -1)
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .animation(DS.motion.select, value: isActive)
        .animation(DS.motion.hover, value: isHovering)
        .contextMenu {
            Button("重命名…") { promptRename() }
            Divider()
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
        .help(tooltip)
    }

    private func promptRename() {
        ui.ask(
            title: "重命名请求",
            placeholder: "请求名称",
            initialValue: session.buffer.name
        ) { newName in
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            store.updateBuffer(tabID: session.id) { $0.name = trimmed }
        }
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

    private var tooltip: String {
        let address = session.buffer.url.isEmpty ? session.displayName : session.buffer.url
        return address
    }

    /// 激活标签用**下方地址栏的同一个底色**，两块连成一片，像浏览器标签那样。
    private var background: Color {
        if isActive { return DS.color.surface }
        // 非激活也要有底：一排标签全透明时彼此没有边界，四个长标题会连成一条读不出来。
        return isHovering ? DS.color.rowHover : DS.color.field.opacity(0.45)
    }

    private var borderColor: Color {
        isActive ? DS.color.border : DS.color.hairline
    }
}
