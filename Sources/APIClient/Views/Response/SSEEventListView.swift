import AppKit
import SwiftUI
import ApiClientCore

/// SSE 流式响应的事件列表：按到达顺序一行一个事件，接收中自动滚到最新一条。
///
/// 每个事件只展示序号 / 事件名 / id / 相对时间 + data 原文（可选中复制）。
/// 不做逐事件的 JSON 树：AI 对话这类流一秒能来几十个事件，树形节点会让列表跟不上。
struct SSEEventListView: View {
    let stream: SSEStreamState

    private static let footerID = "sse-footer"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(stream.events) { event in
                        SSEEventRow(event: event)
                        hairline
                    }
                    footer
                        .id(Self.footerID)
                }
            }
            .onChange(of: stream.events.count) { _, _ in
                // 只在接收中跟随最新事件；结束后用户可能正在往回翻，不打扰。
                guard stream.isOpen else { return }
                proxy.scrollTo(Self.footerID, anchor: .bottom)
            }
        }
        .background(DS.color.sunken)
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.color.hairline)
            .frame(height: 1)
    }

    private var footer: some View {
        HStack(spacing: DS.space.sm) {
            if stream.isOpen {
                SpinnerDot(color: DS.color.info, size: 10)
                Text(stream.events.isEmpty ? "连接已建立，等待服务端推送…" : "接收中，等待下一个事件…")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textSecondary)
            } else {
                AppIcon(symbol: "checkmark.circle", size: 10, tint: DS.color.textTertiary)
                Text("已结束：\(stream.endReason ?? "") · 共 \(stream.events.count) 个事件")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.space.lg)
        .padding(.vertical, DS.space.md)
    }
}

private struct SSEEventRow: View {
    @Environment(AppStore.self) private var store

    let event: SSEEvent

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space.xs) {
            HStack(spacing: DS.space.sm) {
                Text("#\(event.id)")
                    .font(DS.font.monoTiny)
                    .foregroundStyle(DS.color.textTertiary)
                    .frame(width: 44, alignment: .leading)

                CountBadge(text: event.name ?? "message", tint: event.name == nil ? DS.color.textSecondary : DS.color.info)

                if let lastEventID = event.lastEventID, !lastEventID.isEmpty {
                    Text("id: \(lastEventID)")
                        .font(DS.font.monoTiny)
                        .foregroundStyle(DS.color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                }

                Spacer(minLength: DS.space.md)

                if isHovering {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(event.data, forType: .string)
                        store.setNotice("已复制第 \(event.id) 个事件的 data")
                    } label: {
                        AppIcon(symbol: "doc.on.doc", size: 10, tint: DS.color.textTertiary)
                    }
                    .buttonStyle(IconButtonStyle(size: 18, tint: DS.color.textTertiary))
                    .transition(.opacity)
                    .help("复制 data")
                }

                Text(String(format: "+%.2fs", event.receivedAt))
                    .font(DS.font.monoTiny)
                    .foregroundStyle(DS.color.textTertiary)
            }

            Text(event.data)
                .font(DS.font.monoSmall)
                .foregroundStyle(DS.color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 44 + DS.space.sm)
        }
        .padding(.horizontal, DS.space.lg)
        .padding(.vertical, DS.space.sm)
        .background(isHovering ? DS.color.rowHover : Color.clear)
        .onHover { isHovering = $0 }
        .animation(DS.motion.hover, value: isHovering)
    }
}
