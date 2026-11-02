# 输入源切换 HUD 图标取图证据（2026-11 调查）

问题：菜单栏图标为正确的黑色键帽＋透明字形，但系统输入源切换浮层（HUD）里
Gogaku 显示为「裸笔画（只有字形、无外框）」或「白色方块」。

## 结论（置信度：实证，除标注处）

HUD 显示的是 **TextInputSwitcher 进程内缓存的旧 NSImage**，而不是当前安装包里的
键帽 PDF。该进程自 2026-10-30 21:56 起常驻（早于仓库首个提交 11-02 05:25 与首个
键帽图标安装），其 HUD 框架把每个输入源的图标 NSImage 缓存在 `InputSource` 对象
上（反编译可见 ivar `fIconImage`/`fCustomIcon` 等，加载入口
`initWithContentsOfURL:`），进程不重启就不重读文件。首个被它缓存的图标来自
「史前构建」（仓库基线之前，icon-candidates 时代的 menu.svg 本身就是裸笔画设计）。

## 证据链

1. TIS 映射正确且无图标位图缓存（`swift probes/tis-icon-probe.swift`，只读）：
   - `org.gogaku.inputmethod(.Hans)` 的 `kTISPropertyIconImageURL` =
     `~/Library/Input Methods/Gogaku.app/Contents/Resources/gogaku-menu.pdf`，
     存在、可达、3125 字节，与仓库产物 sha256 一致（ca0dbd68…）。
   - 对照组 `app.qingjian.inputmethod(.Hans)` 结构相同（qingjian-menu.pdf）。
   - ABC 走 `kTISPropertyIconRef`（IconRef 0x103），IME 均为 NULL（走图片 URL）。
   - 磁盘缓存：`com.apple.IntlDataCache.le(.kbdx)` 只存输入源注册表与 UI 状态
     （如 Ainu 的 `ZCustomIcon` 文件名），无任何位图；`~/Library/Caches/com.apple.
     tiswitcher.cache` 为 0 字节；TextInputSwitcher 容器目录只有 Metal 缓存。
   - git 历史中从未存在过裸笔画 PDF：176ae8e 与 243a52c 两版 gogaku-menu.pdf
     内容流完全一致（键帽 capsule＋even-odd 镂空字形），仅元数据字节不同。
2. HUD 取图路径（dyld 共享缓存切出 TextInputMenuUI __TEXT 的 ObjC 元数据）：
   `iconImageFromTISImageProperty:` / `initWithContentsOfURL:` / `initWithIconRef:`、
   `TSMInputSourcePropertyIconShouldBeTemplate`、`setTemplate:`；
   HUD nib（HUDPanel.nib）含 `HUDCollectionView`＋`templateView`（集合视图原型项，
   非图像模板）。
3. 渲染路径实验（`swift probes/render-hud-paths.swift`，光栅统计 opaque/black/transparent%）：

   | 路径 | Gogaku PDF | Qingjian PDF | 形态 |
   |---|---|---|---|
   | A NSImage 全彩 | 59.9/59.9/18.8 | 71.6/71.6/14.8 | 键帽（正常） |
   | B alpha 蒙版＋填充 | 同 A | 同 A | 键帽剪影（正常） |
   | B2 反相蒙版 | 18.8/18.8/59.7 | 14.8/14.8/71.6 | 裸笔画（假设路径） |
   | C PDFKit | 100/69.1/0 | 100/77.9/0 | 白底方块（假设路径） |
   | D CGPDFPage | 69.3/69.3/27.9 | 78.1/78.1/20.0 | 键帽（正常） |

   当前 PDF 在所有合理路径（A/B/D）下都是键帽；B2/C 这类病态路径对 Qingjian
   产生同样劣化，故不是 HUD 实际路径，也不构成本 PDF 的缺陷。
4. 时间线：`ps -p 622 -o lstart=` → TextInputSwitcher 2026-10-30 21:56；
   Gogaku 容器目录创建于 10-30 22:01（首个运行）；首个键帽图标资产 mtime
   11-02 11:26；仓库基线提交 11-02 05:25。10-30 的图标管线产物不可考
   （local/icon-candidates 的 menu.svg 即裸笔画＋红点装饰，备份只保留 3 份）。
   「白色方块」对应史前图标加载失败/占位形态：**待真机复核**。
5. 生命周期：`launchctl print gui/$UID` 显示 `com.apple.TextInputSwitcher` 为
   Aqua 按需代理（MachServices 带 ResetAtClose/HideUntilCheckIn），重启后任何
   输入源切换都会拉起新进程重建图标 → `scripts/manage-install.py` 安装流程中的
   `refresh_hud_icon_cache()` 即基于此。

## 本目录 PNG

- `*-A-nsimage-fullcolor.png`：NSImage 全彩（菜单栏同路径）＝键帽。
- `*-B2-inverted-mask.png`：反相蒙版假设＝裸笔画形态（两份 PDF 同样劣化，
  证明该路径不是 HUD 实际路径）。
- `*-C-pdfkit-white.png`：PDFKit 白底＝白色方块形态（同上，非差异路径）。
- `*-D-cgpdf.png`：Quartz 参考渲染＝键帽。

`head-*.png` 为 git HEAD 版 PDF 的同路径渲染，与再生成产物像素逐字节一致。
