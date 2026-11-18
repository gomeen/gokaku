# 共享候选窗位图渲染

2026-11-17：候选窗的横竖排、文字整形、栅格、背景图、透明度与命中区域已收敛到 `shared/GogakuCore/panel_render/`。完整版和 Lite、macOS 和 Windows 使用同一份 C++ 源码，按目标架构编译。平台保留字体文件解析、窗口定位、贴图与点击动作分发。设置应用继续使用原生控件。

## 使用与回退

两版的「普通输入」页新增「渲染引擎：自绘／系统」，默认自绘，对应共享设置 `candidateRenderer=bitmap|system`；缺失或非法值规范化为 `bitmap`。切换随设置热更新生效。选自绘后若字体不可读、帧超限或图片解码失败，该帧自动走系统路径，不修改保存的选择。

系统路径保留原 AppKit／Direct2D 实现，作为过渡期退路，至少保留一个发布版本；删除前须完成双端真实宿主观感、性能与功能验收，并在变更记录中说明。旧系统横排在极长候选场景可能隐藏尾部候选；共享路径缩短每个候选的文字，并保留当前页全部 4–9 个候选的点击区域。

Lite 不发送释义与学习元素，仍保留英文候选、全部主题属性、横竖排和渲染引擎选择。学习模式强制竖排。普通分页、选词和上屏继续由现有会话核心处理，渲染器不生成提交。

## 单一实现与平台边界

| 位置 | 职责 |
| --- | --- |
| `panel_render.h` | 帧、主题、缩放与预乘 RGBA 输出；全局候选索引及翻页／原文／恢复／说明命中区域；统一释放结果 |
| `panel_render/panel_render.cpp` | 横竖排布局、字体覆盖回退、HarfBuzz 整形、FreeType 栅格、PNG 解码、图层合成、文本省略与 UTF-16 问题范围 |
| macOS `SharedPanelBitmap.swift` | CoreText 解析本机字体路径／PostScript 名；转换帧；把 RGBA 转成 CGImage，按屏幕倍数显示 |
| macOS `CandidatePanel.swift`／`InputController.swift` | 非激活窗口、层级、锚点、点击页内索引及已有上屏／翻页逻辑；说明使用共享状态行 |
| Windows `appearance.cpp`／`candidate_window.cpp` | DirectWrite 定位字体；RGBA 转预乘 BGRA DIB，沿用 `UpdateLayeredWindow`；像素坐标命中后调用已有动作 |
| Windows `panel_frame.h` | 核心 UTF-8 字节光标／标量前缀转换为 UTF-16，不另算布局 |

`gc_panel_render` 和 `gc_panel_layout` 共用布局，后者不分配像素。热路径使用附加的 `gc_panel_theme_create`／`gc_panel_render_prepared`／`gc_panel_layout_prepared`：句柄拥有不可变主题快照，主题改变时重建，外观切换复用；最后由 `gc_panel_theme_free` 释放。旧 JSON 入口保留兼容，每线程缓存一个主题，以完整字节比较识别变化，仍有 O(theme_len) 比较；双端逐帧路径不再解析或复制完整主题。

结果由 `gc_panel_result_free` 释放，失败清空输出，异常不跨 C ABI。帧和主题各最多 24MiB、单段文字最多 16KiB、画布最多 4M 像素。`typedPrefixUTF16` 在转换为整数前夹紧到当前预编辑 UTF-16 总长。字体与字形缓存按线程隔离，约 8MiB 字形上限，不缓存帧文字。每个主题句柄只缓存当前外观的一张解码图片，最多 4096×4096 RGBA；并发帧独立持有其图像，释放句柄前调用方须结束所有并发调用。PNG 仍在首次需要像素时同步解码，大图冷加载尚未达到性能目标，见[主题缓存修复记录](validation/bitmap-theme-cache/README.md)。

macOS 从核心 dylib 导出新增 C ABI，不改变现有 ABI v4。Windows x86 文本宿主不能加载 x64 核心，因此独立静态目标 `GogakuPanelRender` 分别编为 x86／x64，链接进 TSF 和设置应用；它不依赖 libime。编译入口与 Mac 使用的源码完全相同。

## 字体与已知差异

- 中文字体由平台按中文家族解析。macOS 默认优先公开可读的 PingFang SC；当前系统私有 PingFangUI 的字形表不受 FreeType 支持，缺少可读苹方时回退系统渲染。不会用日文字体代替产品默认中文字体。离屏核心测试允许显式指定字体。
- 字体通过本地路径和 face index／PostScript 名传入，不随产品打包系统字体。Windows 使用 DirectWrite 返回的本地文件及 face index，Unicode 路径以文件字节方式交给 FreeType。
- 无 hinting advance、浅色 gamma 0.85／深色 0.75；已支持 `opsz`，暂未补 SF 系统字体的 `trak` 表。指定苹方样例与 CoreText 度量接近，不宣称所有字体、字重和字号都与系统完全相同。
- Apple sbix 彩色 emoji 已有本机离屏证据。emoji 固定 strike 的 advance 与位图采用一致缩放；VS15／VS16 区分文本与 emoji 优先级。部分 emoji 字形本身为黑白，不能仅凭彩色像素判断是否使用了 emoji 字体。
- Windows Segoe Emoji、灰度抗锯齿与 D2D 并排观感、跨屏 DPI 热切换仍待 Windows 实机验证。不同系统字体下不承诺像素一致。
- 图片导入仍在平台规范化为 PNG；共享渲染器负责解码与居中填充裁切，整体透明度在所有图层合成后统一乘一次。
- 原生设置页中的主题编辑预览仍有平台自己的绘制路径，不能以预览截图替代真实候选窗验收。无障碍逐候选元素尚未实现。

## 验证方法与边界

共享行为向量为 `shared/GogakuCore/tests/panel_render_test.cpp`，Windows 交叉编译相同文件生成自检 EXE。覆盖横排 4–9 全候选命中、页索引、深浅色、2 倍缩放、预乘透明度、背景图、学习动作、emoji 度量、长预编辑截断后范围连续性、异常输入与所有权。Mac `SharedPanelBitmapTests` 与 Windows `appearance_test.cpp` 另测薄封装转换及回退。

`python3 scripts/verify.py --profile fast` 构建并运行核心和 Swift 回归；`--profile release --only asan-ubsan --quick` 同时执行共享渲染器插桩向量与 2,000 随机输入序列。缺少字体导致跳过不算通过。构建与验证脚本共享测试字体选择，CTest 不缓存配置时的字体路径。

`probes/render-shared-panel.py` 通过 C ABI 输出四主题×深浅色×横竖排的 PNG、命中表、像素哈希与首帧／稳态耗时。哈希只对指定字体和构建可复现，不以系统字体制作跨机器固定 golden。完整执行结果记录在[位图渲染接入验收](validation/bitmap-rendering.md)。

S1 的 Windows 观感及性能门槛尚未完成；[spike 记录](validation/bitmap-renderer-spike.md)已纠正此前“四问全过”的过度表述。离屏耗时不包括宿主读取、窗口提交与实际按键，不能等同逐键 UI 线程 p95≤5ms 或热态候选 p95≤30ms。当前保留回退，真实 IMK／TSF、全部皮肤热更新和当前安装包验收须另行完成。

## 依赖与许可

HarfBuzz、FreeType、libpng、zlib 固定源码静态编入，许可证与裁剪说明随包保存，见[第三方许可](third-party.md)及 `shared/licenses/panel-render-NOTICE.txt`。未引入 tiny-skia；未复制青简源码、词库、模型或字体，仅借鉴其共享渲染与薄平台壳的架构。
