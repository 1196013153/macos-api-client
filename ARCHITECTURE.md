# 架构设计

类 Apifox 的 macOS 原生 API 管理与调试工具。本文说明技术选型理由、分层结构、模块职责、关键数据流，以及若干设计取舍。

---

## 一、技术选型

| 维度 | 选择 | 理由 |
| --- | --- | --- |
| 语言 | Swift 6.3 | 原生应用的主流选择；`async/await` + `URLSession` 直接覆盖 HTTP 引擎需求，无需第三方网络库 |
| UI 框架 | SwiftUI（macOS 14+ API 面） | 声明式、随系统外观自动适配、`@Observable` 状态流与多标签场景天然契合；无需手写 AppKit 视图树 |
| 工程形态 | Swift Package Manager | **不依赖完整 Xcode**。开发机仅装了 Command Line Tools，`xcodebuild` 不可用，而 `swift build` 可用；`.app` 由脚本手工组装，见 `Scripts/build-app.sh` |
| 状态管理 | `@Observable`（Observation 框架）+ `@MainActor` | 细粒度依赖追踪，避免 `ObservableObject` 的全量刷新；上千行集合树场景下差异明显 |
| 网络层 | `URLSession` + 自定义 `URLSessionDelegate` | 系统级能力：连接池、HTTP/2、代理、自签证书处理（`didReceive challenge`），无需自己实现 |
| 持久化 | JSON 文件（`Application Support`） | 纯文本、可读、可 git 管理、可手工修复；不引入数据库依赖 |

### 为什么不是 Electron / Tauri

参考项目（`utools-api-client`）本身是 JS 实现、跑在 uTools 容器里。如果继续用 Web 技术栈，能最大程度复用已有的约 6500 行前端代码——这是它唯一的优势。但需求明确要求「macOS 原生应用程序」，而原生方案换来的是：

- **体积**：4.5 MB 单文件二进制，对比 Electron 的百兆级运行时
- **启动**：无运行时冷启动开销
- **系统集成**：Dock、菜单栏、快捷键、系统外观、`⌘Q` 生命周期回调都是一等公民
- **交付**：`swift build` 直接出可执行文件，不需要打包 node 运行时

代价是 macOS 独占、且无法直接复用参考项目的 JS 代码。参考项目因此被定位为**数据来源**而非代码来源：其导出的工作区格式由 `WACImport` 解析导入，业务语义（变量优先级、路径参数、全局请求头等）也按其设计对齐。

### 为什么不是 Xcode 工程（.xcodeproj）

Xcode 工程无法在没有 Xcode 的机器上构建。SwiftPM + 手工打包脚本可以在任何装了 Command Line Tools 的 macOS 上从零构建出 `.app`，也更适合代码评审时的 diff 阅读（`.pbxproj` 几乎不可读）。

---

## 二、分层结构

```
┌──────────────────────────────────────────────────────────────────┐
│  APIClient（可执行 target）                                        │
│  ── 只负责「渲染」与「把用户意图转成 AppStore 调用」                    │
│                                                                   │
│  RootView ─ NavigationSplitView                                  │
│   ├── SidebarView          项目切换器 + 搜索 + 集合树 + 状态栏         │
│   ├── WorkspaceView                                               │
│   │    ├── TabStripView    跨项目标签条（脏标记 / 发送中 / 项目徽标）    │
│   │    └── RequestWorkspaceView (VSplitView)                      │
│   │         ├── RequestEditorView    方法 / 地址 / 参数 / 头 / 体      │
│   │         └── ResponsePanelView    状态 / 耗时 / JSON 树 / 头 / 详情 │
│   ├── EnvironmentSheet     环境、全局变量、全局请求头                   │
│   ├── SettingsSheet        超时、TLS、重定向、数据目录                  │
│   └── PromptSheet          通用文本输入与确认对话框                     │
│                                                                   │
│  SelfCheck / CLI（--self-check / --import / --info）               │
├──────────────────────────────────────────────────────────────────┤
│  ApiClientCore（库 target）── 不 import SwiftUI，可独立验证          │
│                                                                   │
│  State/     AppStore (@MainActor @Observable)  ← 唯一状态真相源        │
│             ├ 项目 CRUD / 集合树 / 环境 / 变量                       │
│             ├ 标签会话管理（TabSession）                             │
│             ├ 发送编排（resolve → build → send）                     │
│             └ 落盘调度（防抖 + 串行链）                               │
│             TabSession (@MainActor @Observable)                   │
│                                                                   │
│  Services/  VariableResolver   {{var}} 替换 + 内置动态变量            │
│             RequestBuilder     变量 → 路径参数 → 拼 baseURL → query    │
│                                → headers → body（+ cURL 导出）        │
│             HTTPEngine         URLSession 封装、耗时、取消、TLS 开关    │
│             JSONValue          保序 JSON 解析 / 序列化                │
│             PersistenceStore   文件读写（原子写）                     │
│             PersistenceWriter  actor，串行化磁盘写入                  │
│             WACImport          参考项目 wac 格式导入                  │
│                                                                   │
│  Models/    Project / APIRequest / APIEnvironment / CollectionNode │
│             KeyValueItem / RequestBody / TabRef / WorkspaceState   │
└──────────────────────────────────────────────────────────────────┘
```

### 分层的硬约束

- **Core 不依赖 SwiftUI**。所有业务逻辑可在无界面环境下运行，这是 `--self-check` 能在 0.1 秒内跑完 128 项断言的前提。
- **视图不直接改模型**。所有修改都经过 `AppStore.updateProject` / `updateBuffer`，这两处统一负责「标记脏」与「调度落盘」。绕过它就会出现「编辑了但没存」。
- **View 只观察，不持有业务状态**。`TabSession` 是引用类型，视图直接观察它的编辑缓冲与响应变化，不必层层传 Binding。

---

## 三、核心模块职责

| 模块 | 文件 | 职责 | 关键约束 |
| --- | --- | --- | --- |
| `AppStore` | `State/AppStore*.swift` | 中央状态机：项目、标签、设置、发送、落盘 | `@MainActor` 隔离；沿用「唯一修改入口」约定 |
| `TabSession` | `State/TabSession.swift` | 单个标签的编辑缓冲 + 响应 + 发送任务 + 分区与编辑器位置 | 标签属于唯一项目；界面态挂在这里而不是视图 `@State` |
| `VariableResolver` | `Services/VariableResolver.swift` | `{{name}}` 替换、优先级仲裁、内置动态变量 | 未定义变量**原样保留**并上报，不静默变空串 |
| `RequestBuilder` | `Services/RequestBuilder.swift` | 把「接口定义 + 环境」编译成可发送请求 | 纯函数、无副作用；界面用它做实时预览 |
| `MultipartBody` | `Services/MultipartBody.swift` | `multipart/form-data` 编码（含文件名转义、MIME 推断） | 独立成块，逐字节可断言——编码错一个 `\r\n` 服务端只会回 400 |
| `HTTPEngine` | `Services/HTTPEngine.swift` | 发请求、测耗时、取消、按设置处理 TLS / 重定向 | 只暴露 `send` / `cancelAll` |
| `MockEngine` | `Services/MockEngine.swift` | 按请求方法 + 请求体方式生成 Mock 响应 | 纯函数生成；延迟与取消由调用方驱动 |
| `RequestSearch` | `Services/RequestSearch.swift` | 接口搜索：名称/URL/完整URL/备注/方法五目标，子串 + 子序列模糊，分档评分排序 | 纯函数；评分档位全部可单测 |
| `CodeTokenizer` | `Views/Common/CodeSyntax.swift` | JSON 词法着色（键/字符串/数字/字面量/标点） | 只上色不校验；超大文本跳过着色 |
| `TextLocator` | `Models/SessionPresentation.swift` | 正文起点定位、光标夹取 | 纯函数，可单测（自检覆盖） |
| `JSONValue` | `Services/JSONValue.swift` | 保序 JSON 解析与格式化 | 不用 `JSONSerialization`（见下文取舍） |
| `PersistenceStore` | `Services/PersistenceStore.swift` | 文件读写、损坏容忍 | 原子写；坏文件只上报不阻塞启动 |
| `PersistenceWriter` | `Services/PersistenceWriter.swift` | actor，串行磁盘写入 | 主线程不碰 IO |
| `CollectionTree` | `Models/Project.swift` | 集合树扁平化为可见行 + 搜索过滤 | 只构建需要渲染的行 |

---

## 四、数据模型

```
WorkspaceState（workspace.json：界面态，与业务数据分离）
├── activeProjectID
├── openTabs: [TabRef]        ← 只持久化「指向哪个项目/接口」
├── activeTabs: {项目ID: 标签ID} ← 每个项目各自停在哪个标签
├── activeTabID               ← v1 遗留字段，仅用于读老文件
├── collapsedFolderIDs: [UUID] ← 折叠中的目录（v3 起从项目文件挪到这里）
└── settings: AppSettings

Project（projects/<uuid>.json）
├── environments: [APIEnvironment] （含 baseURL 与变量）
├── activeEnvironmentID
├── globals: [KeyValueItem]        （项目全局变量）
├── globalHeaders: [KeyValueItem]  （项目全局请求头）
├── collection: [CollectionNode]   （目录树，请求节点只存 id；`isExpanded` 是 v3 前的遗留字段，只用于迁移）
├── favoriteRequestIDs: [UUID]     （收藏接口，数组顺序 = 置顶顺序）
└── requests: [APIRequest]         （请求定义本体）
     ├── params / headers / body / note …
     ├── body.kind ∈ {none, json, raw, formURLEncoded, formData}
     └── mock: MockConfig           （开关 / 状态码 / 延迟 / 分方式响应体 / 响应头）

KeyValueItem（Params / Headers / 表单 / form-data / 变量共用）
├── key / value / note / location
└── valueKind ∈ {text, file}       （file 时 value 存本地文件的绝对路径）

TabSession（运行时，不落盘）
├── buffer / response / phase      业务运行时
└── activePane / responsePane / responseBodyMode / bodyAnchors
                                   界面态：停在哪个分区、响应怎么展示、
                                   每种请求体方式各自的光标与滚动位置
```

**集合树与请求本体分离**（树节点只持有 `requestID`）是刻意的：树结构变更（增删目录、拖拽）不会触碰请求数据，重命名也只需改一处。

**标签只持久化引用**。编辑缓冲与响应是运行时状态，重启后从接口定义重建——避免「上次没保存的脏数据」在重启后幽灵般复活。

**界面态也挂在标签上**。`TabSession` 存了「停在哪个分区」「响应看树形还是原文」「每种请求体方式各自的光标与滚动位置」。这些不落盘（重启从默认开始），但不该放进视图的 `@State`：视图在切标签时会被复用，`@State` 会把上一个标签的分区带过去——这就是「标签互相干扰」最常见的来源。

`bodyAnchors` 标了 `@ObservationIgnored`：光标每动一下都要写它，若参与观察，整个编辑区会跟着重绘。

---

## 五、关键数据流：一次「发送」

```
用户点发送 / ⌘↵
  │
  ├─ AppStore.send(tabID:)
  │    ├─ settings.shouldMock(buffer) ── 是 ──► MockEngine.respond()（见下）
  │    ├─ RequestBuilder.resolve()
  │    │    ├─ VariableResolver：url / params / headers / body 全部做变量替换
  │    │    ├─ applyPathParams：:id 与 {id} 两种写法
  │    │    ├─ joinURL：相对路径拼环境 baseURL（绝对地址原样保留）
  │    │    ├─ URLComponents：追加 query（自动百分号编码）
  │    │    ├─ headers 合并：全局头 → 请求头覆盖 → 自动补 Content-Type
  │    │    └─ body 编码：json / raw / x-www-form-urlencoded
  │    ├─ RequestBuilder.build()：ResolvedRequest → URLRequest
  │    ├─ session.beginSending(task:)：进入 sending 态，清空上次响应
  │    └─ 异步交给 HTTPEngine
  │
  └─ HTTPEngine.send()
       ├─ 计时 → URLSession dataTask + 每任务 delegate（ResponseCollector）按分块收取
       ├─ 失败：URLError 映射为中文可读原因（超时/连不上/证书...）
       ├─ 成功：状态码 + 响应头 + 原始 Data + 耗时
       └─ 响应头是 text/event-stream：流式模式
            ├─ SSEParser 字节级逐行解析（data / event / id，注释与半行、半个 UTF-8 字符都处理）
            ├─ 每 80 ms 把快照推给 TabSession.receiveStream()（phase = .streaming）
            └─ 服务端关闭 / 用户取消 / 出错 → closeStream(reason:) → finish
              │
              └─ session.finish(with:) → 视图自动刷新
                   ├─ HTTPResponsePayload.text：UTF-8 → charset → GB18030 兜底
                   └─ .jsonValue：JSONValueParser 保序解析
                   （两者都在构造 payload 时算好存下来，且构造发生在 detached Task 里：
                    响应面板每次刷新只读缓存，MB 级响应体不会在主线程反复解码 / 解析）

MockEngine.respond()   ← 命中 Mock 时走这条，不发真实网络
  ├─ 手写响应体非空：直接用（并做变量替换）
  ├─ 否则按「请求方法 + 请求体方式」自动生成：
  │    JSON → 请求体字段镜像进 data ｜ Form → 字段整理成 JSON
  │    Raw  → text/plain 回显原文    ｜ 无请求体 → 回显 query / path 参数
  ├─ 204 / 304 不带响应体
  └─ delayMs → Task.sleep → session.finish(with:)（payload.isMock = true）
```

未解析的变量会一路带上来（`unresolvedVariables`），在响应区顶部以黄条提示，指明「这些变量没定义，已按字面量发出」。

**Mock 分支唯一的特殊处理**：地址解析失败不拦截发送。真实请求路径上「地址为空」属于错误（`failPreparation` 会给出提示），但 Mock 的意义正是后端没就绪时也能联调，所以这一支用 `try?` 拿尽力而为的 `resolved`，拿不到就退化为「按请求原文生成」。

---

## 六、并发与持久化设计

### 串行落盘链

最初每个写入点各自 `Task { await writer.save(...) }`。自检立刻抓到问题：**先入队的写入可能晚于后入队执行**——actor 只保证「到达顺序」，不保证「发起顺序」。极端场景下 `⌘Q` 时最后一次编辑丢失。

现在改为串行链：

```swift
saveChain = Task {
    await previous?.value          // 先等前一个写入完成
    await writer.save(...)          // 再执行自己
}
```

配合两条保障：
- **防抖**：编辑后 500 ms 才落盘，连续打字不会触发 N 次写文件
- **退出拦截**：`applicationShouldTerminate` 返回 `.terminateLater`，等落盘队列排空后再 `reply(toApplicationShouldTerminate: true)`

### 主线程不碰文件 IO

项目 JSON 最大 1.6 MB（单项目 1662 个接口），编码 + 写盘放在 `PersistenceWriter` actor 上执行。实测导入 8 个项目 / 2532 个接口（写入 2.6 MB）耗时 0.10 秒。

---

## 七、关键取舍

**1. 侧边栏把树扁平化，而不是递归渲染**

单项目 1662 个接口 / 267 个目录的规模下，递归渲染意味着 1900+ 个视图节点。`CollectionTree.rows()` 先把「当前展开状态 + 搜索词」下的可见行算成一个数组，折叠状态下通常只有几十行；配合 `LazyVStack` 按需渲染。

同时用一次性构建的 `[UUID: HTTPMethod]` 索引替代逐行线性查找，避免 O(n²)。

几条配套的刷新纪律（都是实际卡过才加的）：

- `sidebarRows` / `sidebarFavorites` / `sidebarSearchResults` 按 `sidebarVersion` 缓存：项目、当前项目、搜索词、折叠状态任一变化才重算一次，body 里读几遍都不再重复计算。
- 行视图只接收 `TreeRow` + `isSelected` / `isFavorite` 两个布尔值，body 里不读 `store`。切标签、收藏时只有状态变了的行会重建。
- 目录的展开 / 折叠状态是界面态，放在 `AppStore.collapsedFolderIDs` 并随 `workspace.json` 落盘。以前存在项目文件的 `isExpanded` 里，展开一个目录 = 重写整个 1.9 MB 的项目文件 + 所有读 `projects` 的视图刷新。
- 搜索框的输入先落在视图本地，停顿 120 ms 再写进 `store.sidebarFilter`。
- 「滚动定位到当前接口」只跟着 `sidebarRevealTicket` 走（切标签、保存新接口时由 `revealRequest` 递增），不再挂在活动标签变化上。`LazyVStack` 里滚到远处的行要先把途中每一行都建出来，几百行就是上百毫秒；树里点的行本来就在眼前，收藏区点击也刻意不展开目录、不定位。定位本身不带动画：动画会把途中每一行分摊到各帧里建，总耗时翻倍还一路掉帧。
- 响应体的 JSON 树同样先扁平化成行（`JSONTreeFlattener`）再交给 `LazyVStack`，展开状态是一个路径集合；「展开全部」几千个节点也只创建视野内的行。

**2. 自己写 JSON 解析器，而不是 `JSONSerialization`**

两个硬伤：
- 字典丢字段顺序，调试时看到的和服务端返回的不是一个顺序
- 数字统一转 `Double`，`1234567890123456789` 这类雪花 ID 会变成 `1.2345678901234568e+18`

现在的 `JSONValue` 把数字按**原始字面量**保存，字段顺序完整保留，UTF-16 代理对（emoji）也正确处理。约 300 行，换来响应展示的准确性。

**3. 单项目单文件**

一个项目一个 JSON。简单、可读、可 git diff。代价是每次保存要重写整个项目文件（最大 1.6 MB）。当前实测可接受；接口量再上一个数量级时应演进为「单请求单文件 + 脏标记差量写入」——参考项目已经验证过这条路径。

**4.5 收藏状态存在项目里，而不是请求里**

收藏（`favoriteRequestIDs`）是 `Project` 上的 id 列表而不是 `APIRequest` 上的布尔位。理由：一是**顺序免费**——数组顺序就是置顶顺序，不需要额外的排序字段；二是「另存为」天然不继承收藏（新 id 不在列表里），不用专门处理；三是删除接口时在 `removeNode` 一处清理即可，和失效标签的清理路径一致。代价是「这个接口被收藏了吗」要查列表（O(n)，收藏数量小，可忽略）。

**4.6 标签分两层：项目标签（顶层）+ 请求标签（下层）**

参考项目（uTools 版）做的是**跨项目标签**：一条标签栏容纳所有项目的标签，切项目不清空。这在「两个项目并排调试」时顺手，但代价是标签一多就分不清归属，「关闭其他标签」还会连带关掉别的项目正在编辑的东西。

中间试过一版「切项目就换一整套标签」——归属清楚了，但切换时别的项目的标签从界面上消失了，用户不知道它们还在不在、去哪了。

最终采用两层结构：

- **顶层**：每个「有标签的项目」一个 tab，同时可见、可点。按项目列表顺序排列（不按打开顺序），所以来回切位置不会跳。tab 上带标签数与未保存圆点，悬停可整组关闭。
- **下层**：当前项目自己的请求标签。

关键点是**切换不清空、也不混合**：切项目 tab 只是换下层那一套，其它项目的标签、编辑缓冲、响应、编辑器位置全部原样保留；而下层永远只有当前一个项目的标签，所以「关闭其他标签」这类批量操作天然不会越界。

实现上复用了「按项目记活动标签」这套模型（`activeTabByProject` + 把 `activeTabID` 做成计算属性），旧调用点 `activeTabID = x` 不用改就自动变成「改当前项目那一份」——比全量改调用点的风险小得多。

**只有一层时不显示顶层**：有标签的项目少于 2 个时，项目条不提供任何信息，还占掉 34pt 内容高度，直接退化为一层。

**5. multipart 自己拼字节，而不是引三方库**

`Alamofire` / `Moya` 都带 multipart 支持，但这个项目本来就只依赖 `URLSession`（见技术选型）。真正的理由是**可控**：

- 编码过程要能被逐字节断言（自检里直接比对 boundary、`Content-Disposition`、`Content-Type`、结尾分隔线），换库就只能「信它是对的」
- 文件缺失必须**在发送前**以明确的错误抛出（`fileNotChosen` / `fileMissing` / `fileTooLarge`），而不是静默少发一个 part
- cURL 导出需要字段清单本身（`FormPart`），而不是编码后的二进制

文件读取同步做（`Data(contentsOf:)`）并设 200 MB 上限：发送本来就是用户主动触发的单次动作，为它引入异步读取链会把 `RequestBuilder` 的纯函数性质破坏掉，收益不值。

**6. 语法高亮自己搭 NSTextView，而不是用 SwiftUI `TextEditor`**

`TextEditor` 拿不到属性字符串，做不了高亮；也读不出「当前滚到哪、光标在哪」，而这两件事正是「每种请求体方式各自记住位置」的前提。所以请求体、Mock 响应体、响应原文三处统一换成了包一层 `NSTextView` 的 `CodeEditor`：

- 高亮的词法分析是自写的（约 150 行），只管 JSON 的键 / 字符串 / 数字 / 字面量 / 标点
- 刻意**不做语法校验**：少个引号时颜色会「断掉」，肉眼比报错信息更快定位
- 超过 20 万字符自动跳过着色，避免大响应体卡顿
- 编辑时只重新着色被改到的那几行（`NSTextStorageDelegate` 记下编辑范围，按段落重算）：JSON 的 token 不跨行，所以局部重算是安全的；整篇 `setAttributes` 会让 NSTextView 全文重排，大请求体每敲一个字就卡一下
- JSON 合法性校验在输入停顿 150 ms 后于后台做一次，不在每次刷新时同步解析
- 关闭自动引号替换、自动大写等「智能」行为（写代码时它们是负担）
- 不自动折行：JSON 折行后层级关系就看不出来了

**7. Mock 默认「按请求自动生成」，而不是给一个空白响应体**

空白 Mock 只是把「起个假服务」的活儿换个地方做。这里的默认值是**从请求推导响应**：JSON 请求体镜像进 `data`、表单字段整理成 JSON、Raw 回显原文、无请求体回显参数。前端拿到的东西结构和真实接口是同一套语义，改一个字段名就能看到连锁反应。

代价是「生成规则」需要被解释，所以 Mock 分区里直接写清了当前规则，并给了「按请求生成」按钮把自动结果填进编辑器，让人可以在此基础上改。

**8. 草稿标签**

`⌘T` 新建的是草稿（没有 `requestID`），`⌘S` 才落库成正式接口。编辑缓冲与已保存定义分离，因此「改了不保存就切走」不会污染项目数据。

---

## 八、与参考项目（uTools 版）的对应

| 能力 | 参考项目 | 本应用 |
| --- | --- | --- |
| 多项目 / 多环境 / 多标签 | ✅ | ✅ |
| 环境变量、全局变量、全局请求头 | ✅ | ✅ |
| 内置动态变量 | ✅（含 `{{$date.year}}` 链式） | ✅（子集） |
| 路径参数 `:id` | ✅ | ✅（另支持 `{id}`） |
| 请求体 JSON / Raw / urlencoded / form-data | ✅ 含文件上传 | 全部支持 ✅（form-data 含文件选择与 multipart 编码） |
| 请求体语法高亮 | ✅ | ✅（JSON，自写词法着色） |
| Mock | ✅（mock.js 语法） | ✅（按请求自动生成 + 手写覆盖） |
| 多标签 | 跨项目共用一条 | 按项目隔离 |
| 前置 / 后置脚本、断言 | ✅ Node vm 沙箱 | ❌ 见路线图 |
| 历史记录 | ✅ | ❌ 见路线图 |
| WebDAV 同步 | ✅ | ❌ 见路线图 |
| Java 源码扫描导入 | ✅ | 复用其导出格式导入（`WACImport`） |
| cURL 导入 / 导出 | 导入 ✅ | 导出 ✅，导入待补 |
| SSE 流式响应 | ✅ | ✅（`Content-Type: text/event-stream` 自动识别，逐块解析、节流刷新） |
| 数据格式 | uTools db / localStorage | JSON 文件（可直接读参考项目导出的 `wac-workspace.json`） |

---

## 九、已知限制与路线图

**限制**

- 仅支持 macOS 14+，未做代码签名与公证（本机自用；分发需开发者证书）
- Mock 不支持像 mock.js 那样的模板语法（`@name` / `@integer(1,100)`）；需要随机数据时用内置动态变量（`{{$randomInt}}` 等）
- 请求超时使用统一值，尚未支持单请求覆盖
- 无请求耗时分解（DNS / TCP / TLS / TTFB）——`URLSessionTaskMetrics` 已具备，只差接线

**路线图（建议顺序）**

1. **前置 / 后置脚本**：用 JavaScriptCore（系统自带）替代 Node vm 沙箱，可覆盖参考项目 90% 的脚本能力；这是与 Apifox 差距最大的一块
1.5 **Mock 模板语法**：给手写响应体加一层 `@name` / `@integer(1,100)` 之类的取值函数，随机数据就不必手搓
2. **历史记录**：独立文件按天分片，附响应摘要，支持一键回填到新标签
3. **集合树拖拽排序**：`CollectionNode` 已具备递归结构，主要是 SwiftUI 拖放交互
4. **单请求单文件存储**：接口量继续增长时的必选项
6. **WebDAV / 本地文件夹同步**
7. **耗时分解与 SSE 的 Mock**
