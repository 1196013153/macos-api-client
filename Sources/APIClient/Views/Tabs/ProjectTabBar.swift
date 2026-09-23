import SwiftUI
import ApiClientCore

/// 顶层项目标签条：每个打开了标签的项目一个 tab。
///
/// 项目层和接口层职责不同，不能合在一条里：
/// - 这里回答「我在哪些项目间切换」，切走后该项目标签、编辑缓冲、响应都保留；
/// - 下面的 `TabStripView` 只显示当前项目的接口标签。
///
/// 只有一个项目有标签时不显示：单独一行只有一个 tab，没有信息量。
struct ProjectTabBar: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    private var projects: [Project] { store.projectsWithTabs }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.space.xs) {
                        ForEach(projects) { project in
                            ProjectTabChip(project: project)
                                .id(project.id)
                        }
                    }
                    .padding(.horizontal, DS.space.md)
                    .padding(.vertical, DS.space.sm)
                }
                .onChange(of: store.activeProjectID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(DS.motion.select) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            Rectangle()
                .fill(DS.color.hairline)
                .frame(width: 1, height: 14)

            HStack(spacing: DS.space.sm) {
                AppIcon(symbol: "square.on.square", size: 10, tint: DS.color.textTertiary)
                    .help("每个项目各自一套标签，切来切去互不影响")
                Text("\(projects.count) 个项目")
                    .font(DS.font.micro)
                    .foregroundStyle(DS.color.textTertiary)
            }
            .padding(.horizontal, DS.space.md)
        }
        .frame(height: DS.metric.projectTabStripHeight)
        .background(DS.color.canvas)
    }
}

/// 单个项目标签。徽标里始终显示该项目打开的标签数，
/// 切走后用户仍能知道那里有几个请求。
private struct ProjectTabChip: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    let project: Project

    @State private var isHovering = false

    private var isActive: Bool { store.activeProjectID == project.id }
    private var tabCount: Int { store.openTabCount(projectID: project.id) }
    private var hasDirty: Bool { store.hasDirtyTabs(projectID: project.id) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.setActiveProject(id: project.id)
            } label: {
                HStack(spacing: DS.space.sm) {
                    RoundedRectangle(cornerRadius: DS.radius.hair, style: .continuous)
                        .fill(isActive ? DS.color.brand : DS.color.textTertiary.opacity(0.45))
                        .frame(width: 3, height: 12)

                    Text(project.name)
                        .font(isActive ? DS.font.captionMedium : DS.font.caption)
                        .foregroundStyle(isActive ? DS.color.textPrimary : DS.color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 148, alignment: .leading)

                    Text("\(tabCount)")
                        .font(DS.font.micro)
                        .foregroundStyle(isActive ? DS.color.brand : DS.color.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(
                            isActive ? DS.color.brand.opacity(0.14) : DS.color.field,
                            in: Capsule()
                        )
                }
                .padding(.leading, DS.space.sm)
                .frame(height: DS.metric.projectTabHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle(scale: 0.97))

            closeArea
                .padding(.trailing, DS.space.xs)
        }
        .background(shape.fill(background))
        .overlay(shape.strokeBorder(isActive ? DS.color.brand.opacity(0.4) : .clear, lineWidth: 1))
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .animation(DS.motion.select, value: isActive)
        .animation(DS.motion.hover, value: isHovering)
        .contextMenu {
            Button("切换到这个项目") { store.setActiveProject(id: project.id) }
            Divider()
            Button("关闭「\(project.name)」的全部标签（\(tabCount)）") {
                TabClosing.closeAll(for: project.id, store: store, ui: ui)
            }
            .disabled(tabCount == 0)
        }
        .help("切换到「\(project.name)」——该项目有 \(tabCount) 个标签，切过去仍停在原来的标签上")
    }

    private var closeArea: some View {
        ZStack {
            if hasDirty, !isHovering {
                DirtyDot()
                    .transition(.opacity)
            }

            if isHovering {
                Button {
                    TabClosing.closeAll(for: project.id, store: store, ui: ui)
                } label: {
                    AppIcon(symbol: "xmark", size: 8, weight: .bold, tint: DS.color.textSecondary)
                }
                .buttonStyle(IconButtonStyle(size: 16))
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                .help("关闭「\(project.name)」的全部 \(tabCount) 个标签")
            }
        }
        .frame(width: 18, height: 18)
    }

    private var background: Color {
        if isActive { return DS.color.brandSoft }
        return isHovering ? DS.color.rowHover : DS.color.field.opacity(0.5)
    }
}
