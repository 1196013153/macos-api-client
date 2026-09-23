import AppKit
import SwiftUI
import ApiClientCore

struct APIClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @State private var ui = UIState()

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environment(store)
                .environment(ui)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 1400, height: 900)
        // 重设计里的顶部是紧凑工具条；系统 unified 标题栏会再垫出一层大标题，
        // 视觉上和内容区断开。这里压成同高的小工具条，让它更像设计稿的一体顶栏。
        .windowToolbarStyle(.unified)
        .commands { AppCommands(store: store, ui: ui) }
    }
}

/// 按设置里的外观偏好给整棵视图套 preferredColorScheme（system = nil 跟随系统）。
private struct ThemedRoot: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        RootView()
            .preferredColorScheme(store.settings.appearance.colorScheme)
    }
}

private extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 退出前把落盘队列排空，避免「刚编辑完就 ⌘Q」丢掉最后一次修改。
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task { @MainActor in
            await store.flushSaveAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// 菜单栏命令与快捷键。
struct AppCommands: Commands {
    let store: AppStore
    let ui: UIState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建请求") {
                store.newDraftTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("新建项目…") {
                store.createProject(name: "新项目 \(store.projects.count + 1)")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("跳转到接口…") {
                ui.commandPalette = true
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("在当前项目内搜索") {
                ui.searchFocusTicket += 1
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            // 关标签的命令必须排在系统自带的「关闭窗口 ⌘W」前面：
            // AppKit 按菜单顺序找第一个匹配且可用的项，放在后面 ⌘W 会直接把窗口关掉。
            Button("关闭当前标签") {
                if let tabID = store.activeTabID {
                    TabClosing.close(tabID, store: store, ui: ui)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(store.activeTabID == nil)

            Button("关闭其他标签") {
                if let tabID = store.activeTabID {
                    TabClosing.closeOthers(keeping: tabID, store: store, ui: ui)
                }
            }
            .disabled(store.visibleSessions.count < 2)

            Button("关闭当前项目的所有标签") {
                if let projectID = store.activeProjectID {
                    TabClosing.closeAll(for: projectID, store: store, ui: ui)
                }
            }
            .disabled(store.visibleSessions.isEmpty)

            Button("关闭所有项目的标签") {
                TabClosing.closeAll(store: store, ui: ui)
            }
            .disabled(store.sessions.isEmpty)
        }

        CommandGroup(after: .saveItem) {
            Button("保存当前标签") {
                if let tabID = store.activeTabID {
                    _ = store.saveTab(tabID: tabID)
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(store.activeTabID == nil)

            Divider()

            Button("上一个项目标签") {
                store.activateAdjacentProjectTab(offset: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(store.projectsWithTabs.count < 2)

            Button("下一个项目标签") {
                store.activateAdjacentProjectTab(offset: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(store.projectsWithTabs.count < 2)
        }

        CommandMenu("请求") {
            Button("发送") {
                if let tabID = store.activeTabID {
                    store.send(tabID: tabID)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(store.activeTabID == nil)

            Button("取消发送") {
                if let tabID = store.activeTabID {
                    store.cancelSend(tabID: tabID)
                }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(store.activeSession?.isSending != true)

            Divider()

            Button("下一个标签") { store.activateAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("上一个标签") { store.activateAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}
