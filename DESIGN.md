# 视觉与交互规范

界面层的唯一视觉来源是 `Sources/APIClient/Views/Common/Theme.swift` 里的 `DS`（Design System）。**视图里不应再出现裸数字或临时拼的颜色**——间距、圆角、字号、动效曲线一律从 `DS` 取。

```swift
DS.color.surface          // 面板底色
DS.space.lg               // 12pt 间距
DS.radius.sm              // 6pt 圆角
DS.font.monoSmall         // 11pt 等宽
DS.motion.select          // 选中动画
DS.metric.barHeight       // 36pt 栏高
```

---

## 一、设计原则

1. **原生优先**：遵循 macOS 的空间感与控件语义。窗口材质、侧边栏、弹窗都交给系统，不自己造轮子。
2. **信息密度优先于留白**：这是调试工具，一屏要多看几行。行高控制在 26–28pt，但靠**层级引导线、语义色和方法徽标**保证可扫读性。
3. **克制用色**：颜色只承担三种职责——语义（成功/警告/危险）、HTTP 方法、JSON 语法。其余全部用中性灰阶。
4. **反馈必须跟手**：悬停 < 150ms，按下 < 100ms，绝不让人怀疑"我点到了吗"。
5. **深浅色同级**：所有颜色通过动态 provider 定义，不写 `if isDark`。

---

## 二、颜色

每个令牌都是 `NSColor(name:dynamicProvider:)`，随系统外观自动切换。下表是两套实际取值。

### 表面

| 令牌 | 用途 | 浅色 | 深色 |
| --- | --- | --- | --- |
| `canvas` | 窗口底色 | 系统 `windowBackgroundColor` | 同左 |
| `surface` | 面板 / 卡片 / 栏 | `#FFFFFF` | `#1F1F22` |
| `sunken` | 编辑器、代码区、标签条 | `#FAFAFC` | `#17171A` |
| `field` | 输入框、内嵌字段 | `#F1F2F5` | `#2A2A2E` |
| `fieldFocused` | 输入框获得焦点 | `#FFFFFF` | `#232327` |
| `elevated` | 选中标签 chip | `#FFFFFF` | `#303036` |

### 线条与交互态

| 令牌 | 用途 | 浅色 | 深色 |
| --- | --- | --- | --- |
| `hairline` | 极细分隔线 | 黑 7% | 白 7% |
| `border` | 常规描边 | 黑 11% | 白 11% |
| `rowHover` | 行悬停底 | 黑 4.5% | 白 5.5% |
| `rowSelected` | 行选中底 | 品牌色 13% | 品牌色 20% |
| `zebra` | 表格斑马纹 | 黑 1.6% | 白 2% |

### 文本

`textPrimary` / `textSecondary` / `textTertiary` 直接映射系统的 `labelColor` / `secondaryLabelColor` / `tertiaryLabelColor`，保证与原生控件同灰度。

### 品牌

| 令牌 | 浅色 | 深色 | 用途 |
| --- | --- | --- | --- |
| `brand` | `#3D6BF5` | `#6E96FF` | 主操作按钮、焦点环、选中指示条、品牌标记 |
| `brandSoft` | 品牌色 10% | 品牌色 18% | 品牌色浅底（药丸、提示条） |
| `brandGradientStart/End` | `#4A7BF7` → `#6B4BDE` | `#7BA2FF` → `#9B7BF0` | 仅品牌标记 |

### 语义

| 令牌 | 浅色 | 深色 |
| --- | --- | --- |
| `success` | `#1E9E5A` | `#41C57F` |
| `warning` | `#D9820B` | `#F0A93B` |
| `danger` | `#D93A3A` | `#F07070` |
| `info` | `#2E7BE0` | `#6EA8FF` |

每个语义色都配一个 `*Soft` 浅底版本（12%–16% 透明度），用于药丸与提示条：`successSoft` / `warningSoft` / `dangerSoft` / `infoSoft`（PUT 徽标、3xx 状态、path 参数指示共用，不再各处内联拼色）。

### HTTP 方法色

GET 绿 / POST 橙 / PUT 蓝 / PATCH 紫 / DELETE 红，各配 `softTint` 浅底用于徽标。

### JSON 语法色

独立于语义色，避免"字符串是红的、报错也是红的"这种混淆：

| 令牌 | 浅色 | 深色 |
| --- | --- | --- |
| `syntaxKey` | `#0B5CAD` | `#7FB3FF` |
| `syntaxString` | `#B4531F` | `#E8A87C` |
| `syntaxNumber` | `#1F6FEB` | `#7CB0FF` |
| `syntaxBool` | `#8250DF` | `#C09BFF` |
| `syntaxNull` | `#6E7781` | `#8B949E` |
| `syntaxPunctuation` | `#8C959F` | `#6E7681` |

---

## 三、间距

4 的倍数体系，命名对应"档位"而非绝对值：

| 令牌 | 值 | 典型用途 |
| --- | --- | --- |
| `hair` | 2 | 图标与文字之间 |
| `xs` | 4 | 徽标内边距、紧凑竖排 |
| `sm` | 6 | 行内元素间隔 |
| `md` | 8 | 栏内水平留白、表单项之间 |
| `lg` | 12 | 区块内边距、栏的水平留白 |
| `xl` | 16 | 卡片内边距、表单分组 |
| `xxl` | 20 | 对话框内边距、区块之间 |
| `xxxl` | 24 | 页面级留白 |
| `huge` | 32 | 空状态插图周围 |

---

## 四、圆角

| 令牌 | 值 | 用途 |
| --- | --- | --- |
| `xs` | 4 | 徽标、语法标记、内嵌小标记 |
| `sm` | 6 | 按钮、输入框、标签 chip、行高亮 |
| `md` | 8 | 卡片、虚线空区 |
| `lg` | 10 | 大卡片、侧边栏容器 |
| `xl` | 14 | 浮层 |
| `pill` | 999 | 胶囊（状态码、预览地址、提示条） |

---

## 五、字体

系统字体（`-apple-system`），等宽用 `SF Mono`。全部通过 `DS.font.*` 取用。

| 令牌 | 字号/字重 | 用途 |
| --- | --- | --- |
| `title` | 15 semibold | 弹窗标题 |
| `heading` | 13 semibold | 区块标题、项目名 |
| `body` / `bodyMedium` | 12 | 正文、行文本 |
| `caption` / `captionMedium` | 11 | 辅助说明、栏内标签 |
| `micro` | 10 semibold | 徽标内文字、分区小标题 |
| `metric` | 20 semibold rounded | 统计数字 |
| `mono` | 12 mono | URL、请求体、响应体 |
| `monoSmall` | 11 mono | 参数键值、响应头、cURL |
| `monoTiny` | 10 mono | 字节数、路径 |
| `badge` / `badgeSmall` | 9 / 8 heavy rounded | HTTP 方法徽标 |
| `methodPicker` | 12 heavy rounded | 地址栏方法选择器 |
| `status` | 11 bold rounded | 响应状态码数字 |

---

## 六、动效

| 令牌 | 曲线 | 用途 |
| --- | --- | --- |
| `hover` | `easeOut 0.12s` | 悬停底色、图标变色 |
| `press` | `easeOut 0.08s` | 按下缩放 |
| `select` | `spring(response 0.28, damping 0.84)` | 选中、展开折叠、指示条滑动 |
| `enter` | `spring(response 0.34, damping 0.86)` | 标签进出、响应内容出现 |
| `toast` | `spring(response 0.38, damping 0.80)` | 底部提示浮出 |
| `shimmer` | `linear 1.15s repeatForever` | 骨架屏扫光 |

**全部动效都受 `accessibilityReduceMotion` 约束**：开启"减弱动态效果"时退化为无动画（`reduceMotion ? nil : DS.motion.xxx`）或静态占位。

---

## 七、尺寸常量

| 令牌 | 值 | 说明 |
| --- | --- | --- |
| `sidebarMin/Ideal/Max` | 230 / 292 / 460 | 侧边栏宽度范围 |
| `listRow` | 26 | 侧边栏树行高 |
| `kvRow` | 28 | 参数表格行高 |
| `barHeight` | 36 | 各类工具条高度 |
| `tabHeight` / `tabStripHeight` | 30 / 40 | 标签与标签条 |
| `headerHeight` | 46 | 弹窗 / 侧边栏头部 |
| `treeIndent` | 13 | 集合树每层缩进 |
| `brand.markSize` | 22 | 品牌标记尺寸 |

---

## 八、组件

全部在 `Views/Common/Components.swift`。

| 组件 | 说明 |
| --- | --- |
| `AppButtonStyle` | 五种角色（prominent / tinted / normal / destructive / ghost）× 两种尺寸，均带悬停与按下反馈，可覆盖主色 |
| `IconButtonStyle` | 图标按钮，悬停浮出圆形底，可指定悬停色（如删除变红） |
| `PressableRowStyle` | 整行可点，按下轻微回弹，不做背景处理 |
| `RowHighlight` | 行悬停 / 选中底色。用 overlay 叠加而非替换背景，因此在侧边栏材质、斑马纹上都能稳定工作 |
| `FieldChrome` | 输入框外观：焦点时描边转品牌色并轻微加粗 |
| `SectionTabBar` | 分区切换，指示条用 `matchedGeometryEffect` 滑动 |
| `ChipTabBar` | 可横向滚动的胶囊分段条（请求体方式、Mock 响应体方式）。**选中项变化时自动滚进视野**，选中态用主色浅底 + 描边 + 图标着色。内部 chip 必须 `.fixedSize(horizontal: true)`——否则横向 ScrollView 会压缩文本而不是让内容溢出，方式一多最后一个 chip 就被截成半截字 |
| `HoverChip` | 操作栏「可点芯片」（Mock 开关 / 地址预览 / 环境菜单 / 方法菜单）的统一外观：圆角矩形、悬停加深、激活态浅底 + 描边。**这些入口都是按钮，必须有悬停反馈**；形状统一圆角矩形，不再胶囊与圆角矩形混用 |
| `ProjectTabBar` / `ProjectTabChip` | 顶层项目标签（每个有标签的项目一个 tab）：项目名 + 标签数胶囊 + 未保存圆点，当前项目用品牌色浅底 + 描边 + 左侧竖条；悬停时右侧圆点变为「关闭该项目全部标签」 |
| `CodeEditor` | 语法高亮代码编辑器（`NSTextView` 包装）。JSON 着色、不折行、横向滚动、可只读；带位置记忆与自动定位 |
| `SkeletonBlock` / `ResponseSkeleton` | 骨架屏，带扫光，减少动态效果时退化为静态灰块 |
| `SpinnerDot` | 细环形加载指示，比 `ProgressView` 更轻且深色按钮上对比度可控 |
| `StatusBadge` | 状态码胶囊，颜色随 2xx/3xx/4xx/5xx 变化 |
| `MethodBadge` | HTTP 方法药丸徽标（浅底 + 方法色） |
| `MetaChip` / `CountBadge` | 指标与计数小胶囊 |
| `ToastView` | 底部提示，含图标、关闭按钮与投影 |
| `SurfaceCard` / `SectionLabel` / `DetailRow` | 卡片、分节标题、键值信息行 |
| `AppIcon` | 统一的图标渲染（尺寸/字重/颜色集中管理） |

---

## 九、代码编辑器

代码编辑器是这套界面里唯一「自绘控件」，因此单独说明规范。

| 维度 | 取值 |
| --- | --- |
| 字体 | `NSFont.monospacedSystemFont(ofSize: 12)`，与 `DS.font.mono` 对应 |
| 内边距 | `DS.space.md`（8pt）四周 |
| 底色 | `DS.color.sunken`（编辑器不自己画背景，交给外层容器） |
| 光标色 | 系统强调色 `controlAccentColor` |
| 折行 | **不折行**，超出横向滚动 |
| 焦点评标 | 由外层 `FieldChrome` 风格统一，编辑器自身不加描边 |
| 着色 | 见「JSON 语法色」一节；键与值刻意用不同色相 |

**被刻意关掉的「智能」行为**：自动引号替换（会写进中文引号）、自动破折号、自动文本替换、拼写检查、智能插入删除。这些对散文有用，对写 JSON 只会制造 bug。

**位置记忆与自动定位**：

- 每个「方式」（`body-json` / `body-raw` / `mock-json` …）各自记一份「光标 + 选中长度 + 滚动位置」
- 切方式、切标签回来，位置原样恢复；首次进入则定位到**正文起点**（跳过前导空行）
- 定位时的滚动是瞬时的，不做补间：这里要的是「立刻出现在该在的地方」，动画反而拖慢

---

## 十、矢量资源

**全部用 `Canvas` + `Path` 矢量绘制，不引入任何位图或 SVG 文件。**

理由：位图在深色模式、任意缩放、不同壁纸下都会失真；而矢量可以直接引用设计令牌，颜色随主题自动切换，也不会给仓库增加二进制资源。

| 资源 | 位置 | 说明 |
| --- | --- | --- |
| `BrandMark` | `Illustrations.swift` | 圆角渐变块 + `{}`，与应用图标同源 |
| `EmptyArt.tabs` | 同上 | 堆叠窗口（含红绿灯 + 内容行）+ 加号角标 |
| `EmptyArt.response` | 同上 | 纸飞机 + 运动弧线 + 虚线地面 |
| `EmptyArt.search` | 同上 | 放大镜 + 散点 |
| `EmptyArt.collection` | 同上 | 文件夹 + 内容行 + 加号角标 |
| `EmptyArt.body` | 同上 | 文档 + 虚线空区 + 斜杠 |
| `AppIcon.icns` | `Resources/` | 由 `Scripts/make-icon.swift` 用 AppKit 离屏绘制生成 |

插图统一在 140×104 的设计坐标系里绘制，`Canvas` 内按目标尺寸等比缩放，因此改尺寸不会失真。

---

## 十一、交互反馈规范

| 场景 | 反馈 |
| --- | --- |
| 行悬停 | 底色浮出（`rowHover`），120ms |
| 行按下 | 缩放至 0.985–0.99 |
| 行选中 | 品牌色浅底 + 加粗字重，弹簧回弹 |
| 按钮悬停 | 底色加深 / 出现底；图标按钮浮出圆形底 |
| 按钮按下 | 缩放至 0.97 |
| 按钮禁用 | 透明度降至 0.38 |
| 输入框聚焦 | 描边转品牌色（1pt），底色变为 `fieldFocused` |
| 展开 / 折叠 | 箭头 90° 旋转，弹簧曲线 |
| 分区切换 | 指示条横向滑动（`matchedGeometryEffect`） |
| 标签新增 / 关闭 | 从左侧缩放淡入，关闭时缩放淡出 |
| 发送中 | 按钮换色为危险色 + 环形转圈，文案变"取消"；响应区显示扫光骨架屏 |
| 响应到达 | 内容淡入落位（`enter` 弹簧） |
| 悬停才能做的操作 | 删除按钮从 0.3 透明度提升到 1 并变红；复制按钮淡入 |
| 提示 | 底部胶囊弹簧浮出，3 秒后自动消失，可手动关闭 |

---

## 十二、Mock 的视觉表达

Mock 是一个**必须一眼看出来**的状态——否则「为什么这个接口返回的是假数据」会变成排查事故。

| 位置 | 表达 |
| --- | --- |
| 发送按钮 | 命中 Mock 时按钮内加 `MOCK` 白字小胶囊 |
| 请求栏 | 常驻 chip：未开启为中性灰、开启为品牌色浅底 + 描边，全量模式显示「Mock 全量」 |
| 分区标签 | `Mock` 分区的徽标显示「开 / 全量」，指示条用品牌色 |
| 响应面板 | 状态码旁一枚品牌色 `MOCK` 胶囊，悬停说明「没有发出真实网络请求」 |
| Mock 分区 | 顶部一行「命中 Mock / 全量 Mock」，编辑区上方注明当前生成规则 |

---

## 十二点五、两级标签的视觉层次

两层标签必须**一眼看出上下级关系**，否则用户会以为它们是同一层的两组标签：

| | 顶层「项目标签」 | 下层「请求标签」 |
| --- | --- | --- |
| 高度 | 24pt（条 34pt） | 30pt（条 40pt） |
| 底色 | `canvas`（与窗口同色，更「远」） | `sunken`（与内容区同色，更「近」） |
| 选中态 | 品牌色浅底 + 描边 + 左侧 3pt 竖条 | 抬升白底（`elevated`）+ 描边 + 阴影 |
| 内容 | 项目名 + 标签数胶囊 + 未保存圆点 | 方法徽标 + 接口名 + 状态位 |
| 出现条件 | 有标签的项目 ≥ 2 | 当前项目有标签时才有标签，否则显示空状态 |

**只有一层时不显示顶层**：一行只有一个 tab 的项目条不提供任何信息，还占掉 34pt 的内容高度。

## 十二点六、文件字段的状态表达

form-data 的文件字段有四种状态，都要能一眼分辨（上传失败最难查的就是「到底有没有带上文件」）：

| 状态 | 表达 |
| --- | --- |
| 未选择 | 中性灰纸夹图标 + 「选择文件…」占位文字 |
| 已选择且存在 | 品牌色文档图标 + 文件名 + 大小（等宽字体） |
| 已选择但文件消失 | **危险色**图标 + 文件名变红 + 「文件已不存在」+ 输入框红边 |
| 已勾选但字段被停用 | 整行降透明度（与键值表格一致） |

只要有任一文件字段处于异常态，编辑区顶部出现危险色提示条，写明「N 个文件字段还不能发送」以及怎么修。发送时会被拦下并自动跳到请求体分区——错误只出现在响应面板而人还停在参数页，是最容易让人懵的组合。

## 十二点七、跟随滚动与布局稳定

评审中补上的两条硬规则：

**凡是「可滚动的条 + 有激活项」，激活项变化时必须自动滚进视野。**
标签条、项目标签条、ChipTabBar 都遵循：键盘切换（⌘⇧] / ⌘⌥]）把焦点切到屏幕外时，条不动比切不动更让人迷惑。统一用 `ScrollViewReader + onChange(of: 激活项) { scrollTo(anchor: .center) }`，动画用 `DS.motion.select`。侧边栏集合树同理：切换标签时滚动定位到当前接口所在行。

**加载期间不能让结构性 chrome 消失。**
发送请求会清空上一次的响应，如果分区条（响应体/响应头/请求详情）依赖「有响应」才显示，它就会随每次发送消失再出现，内容上下跳。规则：chrome 的显示条件要写「有数据**或正在加载**」，骨架只替换内容区。

## 十三、无障碍

- 所有可点击行用 `Button` 而非 `onTapGesture`，自动获得键盘焦点与 VoiceOver 支持。
- 关键操作都有 `.help()` 提示气泡；纯图标按钮一定有。
- 尊重"减弱动态效果"：所有装饰性动画可关闭。
- 装饰性插图标记 `accessibilityHidden(true)`。
- 颜色从不作为唯一信息载体：状态码同时有数字和颜色，参数位置同时有文字和色点。

---

## 十四、界面截图生成

```bash
swift run APIClient --snapshot docs
```

用**屏幕外的真实 NSWindow** 承载视图，跑完一次布局与状态提交后抓取。

> 为什么不用 `ImageRenderer`：它渲染不了需要真实窗口的控件——`TextField` 会变成黄色占位符，`ScrollView` 内容为空，`VSplitView` 直接不渲染。而 `NSHostingView.appearance` 也**不会**改变 SwiftUI 的 `colorScheme`，动态色仍按环境解析，所以深色截图必须同时设置 `\.colorScheme` 环境值。

该命令不需要屏幕录制权限，可在 CI 里生成配图。当前产出：

| 文件 | 内容 |
| --- | --- |
| `screenshot-light.png` / `screenshot-dark.png` | 整体界面（浅色 / 深色） |
| `screenshot-editor.png` | 请求编辑器 + 响应面板 |
| `screenshot-json-highlight.png` | JSON 高亮编辑器 + Mock 响应（MOCK 徽标） |
| `screenshot-formdata.png` | 文件上传（文件字段的异常态同框） |
| `screenshot-project-tabs.png` | 两级标签（顶层项目标签 + 下层请求标签） |
| `screenshot-response-raw.png` | 响应原文（只读高亮、不折行） |
| `screenshot-mock.png` | Mock 分区（开关 / 状态码 / 延迟 / 生成规则） |
| `screenshot-project-menu.png` | 项目切换器（含各项目标签数） |
| `screenshot-empty.png` | 空工作区 |
