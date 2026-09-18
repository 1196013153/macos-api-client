import AppKit
import SwiftUI
import ApiClientCore

/// 离屏渲染界面截图：`APIClient --snapshot <输出目录>`
///
/// 为什么不用 `ImageRenderer`：它渲染不了需要真实窗口的控件——
/// `TextField` 会变成占位符，`ScrollView` 内容为空，`VSplitView` 直接不渲染。
/// 这里改为把视图挂进一个屏幕外的真实 NSWindow，跑完一次布局与状态提交后再抓取，
/// 因此拿到的是和用户所见一致的画面。不需要屏幕录制权限。
@MainActor
enum SnapshotRenderer {

    static func run(outputDirectory path: String) async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let output = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("apiclient-snapshot-\(UUID().uuidString)")
        let store = AppStore(storage: PersistenceStore(root: sandbox))
        let ui = UIState()
        seed(store, sandbox: sandbox)

        let app = RootView()
            .environment(store)
            .environment(ui)

        capture(app, size: CGSize(width: 1440, height: 900), name: "01-overview-light", scheme: .light, into: output)
        capture(app, size: CGSize(width: 1440, height: 900), name: "02-overview-dark", scheme: .dark, into: output)

        capture(
            SidebarView().environment(store).environment(ui),
            size: CGSize(width: 340, height: 760),
            name: "00-sidebar",
            scheme: .light,
            into: output
        )

        if let session = store.activeSession {
            capture(
                detail(session, store: store, ui: ui),
                size: CGSize(width: 1080, height: 860),
                name: "03-request-and-response",
                scheme: .light,
                into: output
            )
        }

        // 搜索模式：按 URL 模糊搜索的平铺结果列表
        store.sidebarFilter = "acco"
        capture(
            SidebarView().environment(store).environment(ui),
            size: CGSize(width: 340, height: 760),
            name: "13-search-results",
            scheme: .light,
            into: output
        )
        store.sidebarFilter = ""

        // 参数分区：键值表格（斑马纹）
        if let paramsSession = store.sessions.first(where: { $0.buffer.name == "账户余额" }) {
            paramsSession.activePane = .params
            capture(
                detail(paramsSession, store: store, ui: ui),
                size: CGSize(width: 1080, height: 860),
                name: "12-params-pane",
                scheme: .light,
                into: output
            )
        }

        // 请求体分区：JSON 高亮 + Mock 开关，右侧是 Mock 生成的响应
        if let mockSession = openMockDemo(store) {
            mockSession.activePane = .body
            capture(
                detail(mockSession, store: store, ui: ui),
                size: CGSize(width: 1080, height: 860),
                name: "05-body-editor",
                scheme: .light,
                into: output
            )

            mockSession.responseBodyMode = .raw
            capture(
                detail(mockSession, store: store, ui: ui),
                size: CGSize(width: 1080, height: 860),
                name: "06-response-raw",
                scheme: .light,
                into: output
            )

            mockSession.activePane = .mock
            mockSession.responseBodyMode = .tree
            capture(
                detail(mockSession, store: store, ui: ui),
                size: CGSize(width: 1080, height: 860),
                name: "07-mock-pane",
                scheme: .light,
                into: output
            )
            capture(
                detail(mockSession, store: store, ui: ui),
                size: CGSize(width: 1080, height: 860),
                name: "08-mock-pane-dark",
                scheme: .dark,
                into: output
            )
        }

        // 空工作区：没有打开任何标签页时的样子
        let emptyStore = AppStore(storage: PersistenceStore(root: sandbox.appendingPathComponent("empty")))
        let empty = WorkspaceView()
            .environment(emptyStore)
            .environment(UIState())
        capture(empty, size: CGSize(width: 1080, height: 560), name: "04-empty-workspace", scheme: .light, into: output)

        // SSE 流式响应：事件列表 + 接收中状态
        if let sseSession = openSSEDemo(store) {
            capture(
                detail(sseSession, store: store, ui: ui),
                size: CGSize(width: 1080, height: 860),
                name: "14-sse-stream",
                scheme: .light,
                into: output
            )
        }

        // 文件上传：文件字段的两种状态（已选好 / 已被移走）
        if let uploadSession = openUploadDemo(store) {
            capture(
                detail(uploadSession, store: store, ui: ui),
                size: CGSize(width: 1080, height: 860),
                name: "10-formdata",
                scheme: .light,
                into: output
            )
        }

        // 两级标签：让第二个项目也开一个标签，再切回主项目
        if let other = store.projects.first(where: { $0.name == "demo-ai-brain" }),
           let otherRequest = other.requests.first {
            store.openRequest(projectID: other.id, requestID: otherRequest.id)
            if let demo = store.projects.first(where: { $0.name == "demo-api" }) {
                store.setActiveProject(id: demo.id)
            }
            capture(
                RootView().environment(store).environment(ui),
                size: CGSize(width: 1440, height: 900),
                name: "11-project-tabs",
                scheme: .light,
                into: output
            )
        }

        // 项目切换器：顺带确认「每个项目各开了几个标签」的提示
        capture(
            ProjectMenu(onDismiss: {})
                .environment(store)
                .environment(ui),
            size: CGSize(width: 272, height: 400),
            name: "09-project-menu",
            scheme: .light,
            into: output
        )

        try? FileManager.default.removeItem(at: sandbox)
        print("截图已输出到 \(output.path)")
        exit(0)
    }

    private static func detail(_ session: TabSession, store: AppStore, ui: UIState) -> some View {
        VStack(spacing: 0) {
            RequestEditorView(session: session)
            Rectangle().fill(DS.color.hairline).frame(height: 1)
            ResponsePanelView(session: session)
        }
        .environment(store)
        .environment(ui)
    }

    /// 另开一张标签演示 Mock：响应直接由 MockEngine 生成，和真实点「发送」拿到的一致。
    private static func openMockDemo(_ store: AppStore) -> TabSession? {
        guard let project = store.projects.first(where: { $0.name == "demo-api" }),
              let search = project.requests.first(where: { $0.name == "商品搜索" }) else { return nil }

        store.openRequest(projectID: project.id, requestID: search.id)
        guard let session = store.activeSession else { return nil }

        store.updateBuffer(tabID: session.id) { request in
            request.mock.isEnabled = true
            request.mock.delayMs = 120
            request.body.text = """
            {
              "keyword": "",
              "page": 1,
              "size": 20,
              "filters": {
                "onlyDiscount": true,
                "maxPrice": 199.9,
                "brandIds": [9527, 10086],
                "couponId": null
              },
              "channel": "{{channel}}"
            }
            """
        }

        guard let liveProject = store.project(id: session.projectID) else { return session }
        let context = RequestBuilder.context(
            project: liveProject,
            environment: liveProject.activeEnvironment,
            runtimeVariables: [:]
        )
        let payload = MockEngine.payload(
            request: session.buffer,
            resolved: store.resolvedRequest(for: session),
            context: context,
            config: session.buffer.mock,
            mode: store.settings.mockMode
        )
        session.finish(with: payload)
        return session
    }

    /// 打开「每日签到」标签，塞一份接收中的 SSE 响应（AI 对话那种 token 流）。
    private static func openSSEDemo(_ store: AppStore) -> TabSession? {
        guard let project = store.projects.first(where: { $0.name == "demo-api" }),
              let sign = project.requests.first(where: { $0.name == "每日签到" }) else { return nil }
        store.openRequest(projectID: project.id, requestID: sign.id)
        guard let session = store.activeSession else { return nil }
        session.activePane = .params

        var payload = HTTPResponsePayload(
            requestURL: "https://api.example.com/test1/demo-api/ai/chat/message",
            method: "POST",
            statusCode: 200,
            statusText: "OK",
            headers: [
                HeaderField(name: "Content-Type", value: "text/event-stream;charset=UTF-8"),
                HeaderField(name: "Cache-Control", value: "no-cache"),
                HeaderField(name: "X-Request-Id", value: "c3d1e9a2-4b77-4f01-9d5c-7e2a1b0f6d44"),
            ],
            elapsed: 0.42
        )
        payload.stream = SSEStreamState()
        let chunks: [(name: String?, data: String, at: TimeInterval)] = [
            ("start", #"{"sessionId":"s_20260917_001","model":"brain-v3"}"#, 0.42),
            (nil, #"{"delta":"今天"}"#, 0.61),
            (nil, #"{"delta":"签到"}"#, 0.68),
            (nil, #"{"delta":"成功，"}"#, 0.74),
            (nil, #"{"delta":"获得 5 积分。"}"#, 0.83),
            ("skill", #"{"name":"price_history","status":"running","goodsId":"1234567890123456789"}"#, 1.12),
        ]
        var parser = SSEParser()
        var raw = ""
        for chunk in chunks {
            var text = ""
            if let name = chunk.name { text += "event: \(name)\n" }
            text += "data: \(chunk.data)\n\n"
            raw += text
            let events = parser.feed(Data(text.utf8), at: chunk.at)
            payload.appendStream(chunk: Data(text.utf8), events: events, elapsed: chunk.at)
        }
        session.beginSending(task: Task {})
        session.receiveStream(payload)
        return session
    }

    /// 打开「上传头像」标签，落在请求体分区（form-data 编辑器在那儿）。
    private static func openUploadDemo(_ store: AppStore) -> TabSession? {
        guard let project = store.projects.first(where: { $0.name == "demo-api" }),
              let upload = project.requests.first(where: { $0.name == "上传头像" }) else { return nil }
        store.openRequest(projectID: project.id, requestID: upload.id)
        guard let session = store.activeSession else { return nil }
        session.activePane = .body
        return session
    }

    // MARK: 抓取

    private static func capture<V: View>(
        _ view: V,
        size: CGSize,
        name: String,
        scheme: ColorScheme,
        into directory: URL
    ) {
        // 注意：NSHostingView.appearance 不会改变 SwiftUI 的 colorScheme，
        // 我们的动态色是按 SwiftUI 环境解析的，所以两边都要设。
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)

        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.orderFrontRegardless()

        // 让 SwiftUI 完成一次完整布局 + 首帧状态提交（onAppear / withAnimation 会被执行）
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        // 手工建 2x 位图：屏幕外窗口的 backingScaleFactor 拿不到 Retina 倍率。
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            print("  ✗ 无法创建位图 \(name)")
            window.orderOut(nil)
            return
        }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("  ✗ PNG 编码失败 \(name)")
            window.orderOut(nil)
            return
        }

        let file = directory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: file)
            print("  ✓ \(file.lastPathComponent)  \(Int(size.width))×\(Int(size.height)) @2x")
        } catch {
            print("  ✗ 写入失败 \(name)：\(error.localizedDescription)")
        }
        window.orderOut(nil)
    }

    // MARK: 演示数据

    private static func seed(_ store: AppStore, sandbox: URL) {
        // 只走公开 API 构造演示项目，避免为了截图给核心库开测试后门。
        let created = store.createProject(
            name: "demo-api",
            baseURL: "https://api.example.com/test1/demo-api"
        )

        let environments = [
            APIEnvironment(
                name: "测试环境1",
                baseURL: "https://api.example.com/test1/demo-api",
                variables: [
                    KeyValueItem(key: "appId", value: "demo-app"),
                    KeyValueItem(key: "token", value: "eyJhbGciOiJIUzI1NiJ9.demo"),
                ]
            ),
            APIEnvironment(name: "本地", baseURL: "http://localhost:8081/demo-api"),
        ]

        // 顺手再建两个项目，让项目切换器与顶层项目标签有内容
        let brain = store.createProject(
            name: "demo-ai-brain",
            baseURL: "https://api.example.com/test1/ai-brain"
        )
        let profile = APIRequest(
            name: "用户画像",
            method: .get,
            url: "/agent/profile/:userId",
            params: [KeyValueItem(key: "userId", value: "10086", note: "用户 ID", location: .path)],
            note: "读取用户画像，用于演示另一个项目自己的标签。"
        )
        store.updateProject(id: brain.id) { project in
            var folder = CollectionNode.folder(name: "AgentController")
            folder.children = [CollectionNode.request(id: profile.id, name: profile.name)]
            project.collection = [folder]
            project.requests = [profile]
        }
        _ = store.createProject(name: "demo-item", baseURL: "https://api.example.com/test1/item")

        // 去掉首次启动自动创建的示例项目，让截图只保留演示数据
        if let starter = store.projects.first(where: { $0.name == "我的第一个项目" }) {
            store.deleteProject(id: starter.id)
        }

        let balance = APIRequest(
            name: "账户余额",
            method: .post,
            url: "/account/balance",
            params: [
                KeyValueItem(key: "scene", value: "1", note: "场景", location: .query),
                KeyValueItem(key: "date", value: "{{$date}}", note: "日期", location: .query),
            ],
            headers: [KeyValueItem(key: "X-Trace-Id", value: "{{$uuid}}")],
            body: RequestBody(
                kind: .json,
                text: "{\n  \"scene\": 1,\n  \"date\": \"{{$date}}\",\n  \"appId\": \"{{appId}}\"\n}"
            ),
            note: "查询当前用户可用余额与冻结金额。"
        )

        let detail = APIRequest(
            name: "账户明细",
            method: .get,
            url: "/account/detail/:id",
            params: [
                KeyValueItem(key: "id", value: "10086", note: "用户 ID", location: .path),
                KeyValueItem(key: "page", value: "1", location: .query),
                KeyValueItem(key: "size", value: "20", location: .query),
            ]
        )

        let sign = APIRequest(
            name: "每日签到",
            method: .post,
            url: "/account/sign",
            body: RequestBody(
                kind: .formURLEncoded,
                fields: [
                    KeyValueItem(key: "source", value: "app"),
                    KeyValueItem(key: "channel", value: "{{channel}}"),
                ]
            )
        )

        let goods = APIRequest(name: "商品详情", method: .get, url: "/goods/detail/:id", params: [
            KeyValueItem(key: "id", value: "9527", location: .path)
        ])
        let search = APIRequest(name: "商品搜索", method: .post, url: "/goods/search", body: RequestBody(
            kind: .json,
            text: "{\n  \"keyword\": \"\",\n  \"page\": 1\n}"
        ))

        // 文件上传演示：一个选好的文件 + 一个已被移走的文件，两种状态同框
        let uploadDirectory = sandbox.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        let keptFile = uploadDirectory.appendingPathComponent("avatar-2026.png")
        try? Data(count: 240 * 1024).write(to: keptFile)
        let removedFile = uploadDirectory.appendingPathComponent("design-review.pdf")

        let upload = APIRequest(
            name: "上传头像",
            method: .post,
            url: "/file/upload",
            params: [KeyValueItem(key: "biz", value: "avatar", note: "业务标识", location: .query)],
            body: RequestBody(
                kind: .formData,
                fields: [
                    KeyValueItem(key: "biz", value: "avatar", note: "业务场景"),
                    KeyValueItem(key: "file", value: keptFile.path, note: "头像图片", valueKind: .file),
                    KeyValueItem(key: "cover", value: removedFile.path, note: "原文件已被移走", valueKind: .file),
                ]
            ),
            note: "multipart/form-data：文件字段直接选本机文件，发送时按 multipart 编码。"
        )

        var accountFolder = CollectionNode.folder(name: "AccountController")
        accountFolder.children = [balance, detail, sign].map {
            CollectionNode.request(id: $0.id, name: $0.name)
        }

        var goodsFolder = CollectionNode.folder(name: "GoodsController")
        goodsFolder.children = [goods, search].map {
            CollectionNode.request(id: $0.id, name: $0.name)
        }

        var fileFolder = CollectionNode.folder(name: "FileController")
        fileFolder.children = [CollectionNode.request(id: upload.id, name: upload.name)]

        store.updateProject(id: created.id) { project in
            project.note = "演示数据"
            project.environments = environments
            project.activeEnvironmentID = environments.first?.id
            project.globals = [
                KeyValueItem(key: "channel", value: "ios"),
                KeyValueItem(key: "appVersion", value: "6.8.0"),
            ]
            project.globalHeaders = [
                KeyValueItem(key: "version", value: "6.8.0", note: "App 版本号"),
                KeyValueItem(key: "timestamp", value: "{{$timestampMs}}"),
                KeyValueItem(key: "Authorization", value: "Bearer {{token}}"),
            ]
            project.collection = [accountFolder, goodsFolder, fileFolder]
            project.requests = [balance, detail, sign, goods, search, upload]
            // 收藏两个接口：侧边栏「收藏」区有内容可展示
            project.favoriteRequestIDs = [balance.id, upload.id]
        }

        store.setActiveProject(id: created.id)
        // 演示一个折叠着的目录
        store.toggleFolder(projectID: created.id, nodeID: goodsFolder.id)
        store.openRequest(projectID: created.id, requestID: balance.id)

        // 造一份响应，让响应面板有内容可看
        guard let session = store.activeSession else { return }
        let json = """
        {
          "code": 0,
          "message": "success",
          "data": {
            "userId": 1234567890123456789,
            "balance": 1280.55,
            "frozen": 0,
            "currency": "CNY",
            "level": 3,
            "vip": true,
            "tags": ["新客", "高活跃", "已实名"],
            "profile": {
              "nickname": "小布",
              "avatar": "https://cdn.example.com/a.png",
              "registeredAt": "2024-03-11 09:20:15"
            },
            "lastOrderAt": "2026-09-15 21:04:33",
            "ext": null
          },
          "traceId": "8f2c1a4e-77b3-4a90-9c21-0a5f6d1e2233"
        }
        """
        session.finish(
            with: HTTPResponsePayload(
                requestURL: "https://api.example.com/test1/demo-api/account/balance?scene=1",
                method: "POST",
                statusCode: 200,
                statusText: "OK",
                headers: [
                    HeaderField(name: "Content-Type", value: "application/json;charset=UTF-8"),
                    HeaderField(name: "Server", value: "nginx/1.24.0"),
                    HeaderField(name: "X-Request-Id", value: "8f2c1a4e-77b3-4a90-9c21-0a5f6d1e2233"),
                ],
                body: Data(json.utf8),
                elapsed: 0.184
            )
        )
    }
}
