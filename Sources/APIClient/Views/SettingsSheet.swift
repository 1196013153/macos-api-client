import AppKit
import SwiftUI
import ApiClientCore

struct SettingsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            ScrollView {
                VStack(alignment: .leading, spacing: DS.space.xxl) {
                    appearanceSection
                    networkSection
                    mockSection
                    dataSection
                    shortcutSection
                }
                .padding(DS.space.xxl)
            }
        }
        .frame(width: 580, height: 620)
        .background(DS.color.canvas)
    }

    // MARK: 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: DS.space.md) {
            SectionLabel(text: "外观", detail: "跟随系统或固定浅色 / 深色")

            SurfaceCard {
                HStack(spacing: DS.space.md) {
                    Text("主题")
                        .font(DS.font.body)
                        .foregroundStyle(DS.color.textPrimary)

                    Spacer(minLength: DS.space.lg)

                    Picker("", selection: Binding(
                        get: { store.settings.appearance },
                        set: { newValue in
                            store.updateSettings { $0.appearance = newValue }
                        }
                    )) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 240)
                }
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(DS.color.hairline).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: DS.space.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
                    .fill(DS.color.brandSoft)
                    .frame(width: 28, height: 28)
                AppIcon(symbol: "gearshape", size: 13, tint: DS.color.brand)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("设置")
                    .font(DS.font.title)
                    .foregroundStyle(DS.color.textPrimary)
                Text("外观主题、网络行为、数据存储与快捷键")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
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

    // MARK: 网络

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: DS.space.md) {
            SectionLabel(text: "网络", detail: "对所有请求生效")

            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.space.lg) {
                    stepperRow(
                        title: "请求超时",
                        detail: "单个请求最长等待时间",
                        value: store.settings.requestTimeout,
                        range: 1...600,
                        unit: "秒",
                        onChange: { newValue in
                            store.updateSettings { $0.requestTimeout = newValue }
                        }
                    )

                    hairline

                    toggleRow(
                        title: "校验 TLS 证书",
                        detail: "关闭后可直连使用自签证书的测试环境（有安全风险）",
                        isOn: store.settings.verifyTLS,
                        onChange: { newValue in
                            store.updateSettings { $0.verifyTLS = newValue }
                        }
                    )

                    hairline

                    toggleRow(
                        title: "跟随重定向",
                        detail: "关闭后 3xx 响应会原样返回，便于检查跳转逻辑",
                        isOn: store.settings.followRedirects,
                        onChange: { newValue in
                            store.updateSettings { $0.followRedirects = newValue }
                        }
                    )
                }
            }
        }
    }

    // MARK: Mock

    private var mockSection: some View {
        VStack(alignment: .leading, spacing: DS.space.md) {
            SectionLabel(text: "Mock", detail: "后端没就绪时用模拟响应把链路跑通")

            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.space.lg) {
                    HStack(spacing: DS.space.md) {
                        Text("生效范围")
                            .font(DS.font.body)
                            .foregroundStyle(DS.color.textPrimary)

                        Spacer(minLength: DS.space.lg)

                        Picker("", selection: Binding(
                            get: { store.settings.mockMode },
                            set: { newValue in
                                store.updateSettings { $0.mockMode = newValue }
                            }
                        )) {
                            ForEach(MockMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 208)
                    }

                    Text(store.settings.mockMode.detail)
                        .font(DS.font.caption)
                        .foregroundStyle(DS.color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    hairline

                    HStack(alignment: .top, spacing: DS.space.sm) {
                        AppIcon(symbol: "wand.and.rays", size: 10, tint: DS.color.brand)
                        Text("接口的 Mock 响应体会跟着请求方法与请求体方式自动生成："
                            + "JSON 请求体镜像进 data，表单字段整理成 JSON，Raw 回显原文。"
                            + "需要固定返回值时，在请求的 Mock 分区里手写覆盖。")
                            .font(DS.font.caption)
                            .foregroundStyle(DS.color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 数据

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: DS.space.md) {
            SectionLabel(text: "数据", detail: "所有项目以纯 JSON 文件保存在本机")

            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.space.md) {
                    HStack(spacing: DS.space.md) {
                        AppIcon(symbol: "folder", size: 12, tint: DS.color.textSecondary)
                        Text(store.storageRootPath)
                            .font(DS.font.monoSmall)
                            .foregroundStyle(DS.color.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("打开") {
                            store.flushSave()
                            NSWorkspace.shared.open(URL(fileURLWithPath: store.storageRootPath))
                        }
                        .buttonStyle(AppButtonStyle(kind: .normal, size: .small))
                    }

                    HStack(spacing: DS.space.sm) {
                        AppIcon(symbol: "exclamationmark.triangle.fill", size: 10, tint: DS.color.warning)
                        Text("环境变量以明文存储（含 token、密钥），共享或同步该目录前请自行评估。")
                            .font(DS.font.caption)
                            .foregroundStyle(DS.color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, DS.space.md)
                    .padding(.vertical, DS.space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.color.warningSoft, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
                }
            }
        }
    }

    // MARK: 快捷键

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: DS.space.md) {
            SectionLabel(text: "快捷键")

            SurfaceCard {
                VStack(spacing: DS.space.sm) {
                    let items: [(String, String)] = [
                        ("⌘ ↵", "发送请求"),
                        ("⌘ .", "取消发送"),
                        ("⌘ S", "保存当前标签"),
                        ("⌘ T", "新建请求标签"),
                        ("⌘ W", "关闭当前标签"),
                        ("⌘ ⇧ ] / [", "切换请求标签"),
                        ("⌘ ⌥ ] / [", "切换项目标签"),
                        ("⌘ ,", "打开设置"),
                    ]
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: DS.space.lg) {
                            Text(item.0)
                                .font(DS.font.monoSmall)
                                .foregroundStyle(DS.color.textPrimary)
                                .padding(.horizontal, DS.space.sm)
                                .padding(.vertical, 2)
                                .background(DS.color.field, in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
                                .frame(width: 92, alignment: .leading)
                            Text(item.1)
                                .font(DS.font.body)
                                .foregroundStyle(DS.color.textSecondary)
                            Spacer(minLength: 0)
                        }
                        if index != items.count - 1 {
                            hairline
                        }
                    }
                }
            }
        }
    }

    // MARK: 行

    private func toggleRow(
        title: String,
        detail: String,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: DS.space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.font.body)
                    .foregroundStyle(DS.color.textPrimary)
                Text(detail)
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.space.lg)

            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func stepperRow(
        title: String,
        detail: String,
        value: TimeInterval,
        range: ClosedRange<Double>,
        unit: String,
        onChange: @escaping (TimeInterval) -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: DS.space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.font.body)
                    .foregroundStyle(DS.color.textPrimary)
                Text(detail)
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
            }

            Spacer(minLength: DS.space.lg)

            HStack(spacing: DS.space.sm) {
                TextField("", value: Binding(get: { value }, set: onChange), format: .number)
                    .textFieldStyle(.plain)
                    .font(DS.font.monoSmall)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, DS.space.sm)
                    .frame(width: 62, height: 24)
                    .background(DS.color.field, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))

                Stepper("", value: Binding(get: { value }, set: onChange), in: range, step: 5)
                    .labelsHidden()
                    .controlSize(.small)

                Text(unit)
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
                    .frame(width: 18, alignment: .leading)
            }
        }
    }
}
