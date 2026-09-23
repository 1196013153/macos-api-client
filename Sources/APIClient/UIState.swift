import SwiftUI
import ApiClientCore

/// 界面态：弹窗、对话框、临时选择。与业务数据（AppStore）分开，避免污染模型层。
@MainActor
@Observable
final class UIState {

    struct Prompt: Identifiable {
        let id = UUID()
        var title: String
        var message: String?
        var placeholder: String = ""
        var initialValue: String = ""
        var confirmTitle: String = "确定"
        var onConfirm: (String) -> Void
    }

    struct Confirm: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var confirmTitle: String = "删除"
        var isDestructive: Bool = true
        /// 第三个按钮（如「保存并关闭」）；nil 时只有确认 / 取消两个。
        var alternateTitle: String?
        var onAlternate: (() -> Void)?
        var onConfirm: () -> Void
    }

    enum Sheet: Identifiable {
        case environment(UUID)
        case settings
        case requestDetail(UUID)   // projectID

        var id: String {
            switch self {
            case .environment(let id): return "env-\(id.uuidString)"
            case .settings: return "settings"
            case .requestDetail(let id): return "detail-\(id.uuidString)"
            }
        }
    }

    var sheet: Sheet?
    var prompt: Prompt?
    var confirm: Confirm?
    /// ⌘F「在当前项目内搜索」：每按一次 +1，侧边栏据此把焦点移到搜索框。
    var searchFocusTicket = 0
    /// ⌘K 命令面板：跨项目跳接口。
    var commandPalette = false

    func ask(
        title: String,
        message: String? = nil,
        placeholder: String = "",
        initialValue: String = "",
        confirmTitle: String = "确定",
        onConfirm: @escaping (String) -> Void
    ) {
        prompt = Prompt(
            title: title,
            message: message,
            placeholder: placeholder,
            initialValue: initialValue,
            confirmTitle: confirmTitle,
            onConfirm: onConfirm
        )
    }

    func askDelete(title: String, message: String, onConfirm: @escaping () -> Void) {
        confirm = Confirm(title: title, message: message, onConfirm: onConfirm)
    }

    func askConfirm(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = true,
        alternateTitle: String? = nil,
        onAlternate: (() -> Void)? = nil,
        onConfirm: @escaping () -> Void
    ) {
        confirm = Confirm(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            isDestructive: isDestructive,
            alternateTitle: alternateTitle,
            onAlternate: onAlternate,
            onConfirm: onConfirm
        )
    }
}
