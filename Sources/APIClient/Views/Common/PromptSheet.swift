import AppKit
import SwiftUI
import ApiClientCore

/// 通用文本输入对话框（新建项目 / 重命名 / 新建文件夹共用）。
struct PromptSheet: View {
    let prompt: UIState.Prompt
    let onClose: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space.xl) {
            HStack(spacing: DS.space.lg) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
                        .fill(DS.color.brandSoft)
                        .frame(width: 30, height: 30)
                    AppIcon(symbol: "square.and.pencil", size: 14, tint: DS.color.brand)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.title)
                        .font(DS.font.title)
                        .foregroundStyle(DS.color.textPrimary)
                    if let message = prompt.message {
                        Text(message)
                            .font(DS.font.caption)
                            .foregroundStyle(DS.color.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            TextField(prompt.placeholder, text: $text)
                .fieldChrome(isFocused: isFocused, height: 30)
                .focused($isFocused)
                .onSubmit(confirm)

            HStack(spacing: DS.space.md) {
                Spacer()

                Button("取消", action: onClose)
                    .buttonStyle(AppButtonStyle(kind: .normal))
                    .keyboardShortcut(.cancelAction)

                Button(prompt.confirmTitle, action: confirm)
                    .buttonStyle(AppButtonStyle(kind: .prominent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.space.xxl)
        .frame(width: 420)
        .background(DS.color.canvas)
        .onAppear {
            text = prompt.initialValue
            isFocused = true
        }
    }

    private func confirm() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        prompt.onConfirm(value)
        onClose()
    }
}

/// 项目信息：重命名、备注、统计、导出。
struct ProjectDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID

    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case name
        case note
    }

    private var project: Project? { store.project(id: projectID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            if let project {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.space.xxl) {
                        identitySection(project)
                        statSection(project)
                        javaSyncSection(project)
                        storageSection(project)
                    }
                    .padding(DS.space.xxl)
                }
            } else {
                EmptyState(art: .search, title: "项目不存在")
            }
        }
        .frame(width: 560, height: 560)
        .background(DS.color.canvas)
    }

    private var hairline: some View {
        Rectangle().fill(DS.color.hairline).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: DS.space.lg) {
            BrandMark(size: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text("项目信息")
                    .font(DS.font.title)
                    .foregroundStyle(DS.color.textPrimary)
                Text(project?.name ?? "")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button("完成") { dismiss() }
                .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, DS.space.xl)
        .frame(height: DS.metric.headerHeight + 8)
        .background(DS.color.surface)
    }

    private func identitySection(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: DS.space.md) {
            SectionLabel(text: "名称与备注")

            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.space.lg) {
                    VStack(alignment: .leading, spacing: DS.space.sm) {
                        Text("项目名称")
                            .font(DS.font.captionMedium)
                            .foregroundStyle(DS.color.textSecondary)
                        TextField("项目名称", text: Binding(
                            get: { project.name },
                            set: { newValue in store.renameProject(id: projectID, to: newValue) }
                        ))
                        .fieldChrome(isFocused: focusedField == .name, height: 26)
                        .focused($focusedField, equals: .name)
                    }

                    VStack(alignment: .leading, spacing: DS.space.sm) {
                        Text("备注")
                            .font(DS.font.captionMedium)
                            .foregroundStyle(DS.color.textSecondary)
                        TextEditor(text: Binding(
                            get: { project.note },
                            set: { newValue in store.updateProject(id: projectID) { $0.note = newValue } }
                        ))
                        .font(DS.font.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 72)
                        .padding(DS.space.sm)
                        .background(DS.color.field, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
                                .strokeBorder(DS.color.hairline)
                        )
                    }
                }
            }
        }
    }

    private func statSection(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: DS.space.md) {
            SectionLabel(text: "概况")

            HStack(spacing: DS.space.md) {
                statCard("接口", "\(project.requests.count)", symbol: "arrow.left.arrow.right", tint: DS.color.brand)
                statCard("目录", "\(project.collection.count)", symbol: "folder", tint: DS.color.info)
                statCard("环境", "\(project.environments.count)", symbol: "globe", tint: DS.color.success)
                statCard("全局请求头", "\(project.globalHeaders.activeItems.count)", symbol: "list.bullet.rectangle", tint: DS.color.warning)
            }
        }
    }

    private func statCard(_ title: String, _ value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.space.sm) {
            AppIcon(symbol: symbol, size: 12, tint: tint)
            Text(value)
                .font(DS.font.metric)
                .foregroundStyle(DS.color.textPrimary)
            Text(title)
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.space.lg)
        .background(DS.color.surface, in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous)
                .strokeBorder(DS.color.hairline)
        )
    }

    private func javaSyncSection(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: DS.space.md) {
            SectionLabel(text: "Java 接口同步", detail: "查看当前项目绑定的源码目录与最近同步时间")

            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.space.lg) {
                    HStack(alignment: .top, spacing: DS.space.md) {
                        AppIcon(symbol: "folder.badge.gearshape", size: 11, tint: DS.color.textSecondary)

                        Text(project.javaSyncFolderPath ?? "未绑定 Java 项目目录")
                            .font(DS.font.monoTiny)
                            .foregroundStyle(project.javaSyncFolderPath == nil ? DS.color.textTertiary : DS.color.textPrimary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let syncedAt = project.javaSyncedAt {
                        Text("最近同步：\(syncedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(DS.font.caption)
                            .foregroundStyle(DS.color.textSecondary)
                    }

                    if let path = project.javaSyncFolderPath {
                        HStack(spacing: DS.space.sm) {
                            Button("打开目录") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                            .buttonStyle(AppButtonStyle(kind: .normal, size: .small))

                            Button("复制路径") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(path, forType: .string)
                                store.setNotice("已复制同步目录路径")
                            }
                            .buttonStyle(AppButtonStyle(kind: .normal, size: .small))
                        }
                    }
                }
            }
        }
    }

    private func storageSection(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: DS.space.md) {
            SectionLabel(text: "存储与导出", detail: "项目以单个 JSON 文件保存，可直接 diff 或纳入版本管理")

            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.space.lg) {
                    HStack(spacing: DS.space.md) {
                        AppIcon(symbol: "doc.text", size: 11, tint: DS.color.textSecondary)
                        Text(store.storage.paths.projectFile(project.id).path)
                            .font(DS.font.monoTiny)
                            .foregroundStyle(DS.color.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    hairline

                    HStack(spacing: DS.space.md) {
                        Button {
                            guard let url = FileDialogs.saveJSON(defaultName: "\(project.name).json") else { return }
                            store.exportProject(id: project.id, to: url)
                        } label: {
                            HStack(spacing: DS.space.xs) {
                                AppIcon(symbol: "square.and.arrow.up", size: 10, tint: DS.color.brand)
                                Text("导出")
                                    .font(DS.font.caption)
                            }
                        }
                        .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(project.activeEnvironment?.baseURL ?? "", forType: .string)
                            store.setNotice("已复制 baseURL")
                        } label: {
                            HStack(spacing: DS.space.xs) {
                                AppIcon(symbol: "doc.on.doc", size: 10, tint: DS.color.textSecondary)
                                Text("复制 baseURL")
                                    .font(DS.font.caption)
                            }
                        }
                        .buttonStyle(AppButtonStyle(kind: .normal, size: .small))

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
