# 原生候选窗主题验收

更新：2026-11-05。实现及验证在 `/Users/gomeen/orca/workspaces/gogaku/skin-native` 完成，开发分支 `gomeen/skin-native`，基于 `27428de0`；未制作安装包、未替换当前输入法。功能与格式见[皮肤说明](../skin-themes.md)。

## 已实现

- 四套内置主题和用户主题目录；一级页面统一选择主题，双色跟随系统、单色共用。Claude 浅色背景 `#f5f4f1`、Grok Bot `#f5f5f5`，与最后原型一致。旧 `rime-macos-like` 保留旧颜色、无边框和全局字号；缺失／未知 ID 回退旧默认。
- 原生新建、复制、编辑、保存、删除、应用；独立草稿和未保存确认覆盖返回、切页、关窗及应用退出。保存失败不返回列表、不应用、不发送成功通知。
- 名称、中文／英文字体、候选／序号字号、圆角、间距、行高、三种透明度、十项颜色、各外观背景图，单／双色转换与实时九条预览。字体共用，颜色及视觉参数按浅深独立保存。
- `.gogakutheme` ZIP 导入导出，图片真实解码和 PNG 规范化；路径、重复项、特殊文件、CRC、压缩方式及大小校验。导入分配新用户 ID，不能覆盖内置。
- 输入法按设置加载色板和缓存图片；同一 ID 编辑后重新解析，外观变化更新字体、布局和颜色。SettingsStore 按顶层字段合并，隔离坏条目，兼容旧文件缺少新增字段；编码失败不写盘。

## 自动验证

- `python3 scripts/verify.py --profile fast`：6 项全过；核心 ctest 全过、Swift Release **152 项**全过，翻译评测与 worker 协议回归通过。报告：[report-fast-20261105-113157.json](verify/report-fast-20261105-113157.json)。开发过程的中间报告保留在原开发 worktree 的 `.build/skin-development-evidence/`，不作为通过证据提交。
- `--profile release --only asan-ubsan --quick`：**2000 随机序列无 ASan／UBSan 错误**，见[报告](verify/report-release-20261105-114244.json)。仅选中该检查，其余发布门槛跳过，因此脚本总退出码为 1；不代表完整 release 档通过，也不满足十万序列门槛。
- `swift build -c release --product GogakuSettings`：最终源码构建成功。`git diff --check` 通过。
- 新增测试覆盖色板／字体／视觉参数往返、非法值、旧版渲染兼容、同 ID 内容更新、双外观与单外观、真实离屏透明度、背景图缓存、用户主题隔离、设置并发合并、写盘失败、草稿复制隔离，以及主题包损坏／压缩／图片格式等拒绝路径。

## 真实设置窗口

使用独立 `org.gogaku.skin-review` 应用、独立 `.build/skin-review-support` 配置目录，设置 `GOGAKU_DISABLE_SETTINGS_NOTIFICATIONS=1`。所有设置操作只作用于该目录；没有向真实宿主注入按键。

- 一级与二级窗口均为 **1100×800pt**；编辑页左配置、右预览，中间竖线，没有额外圆角容器背景；默认显示九条，无展开按钮。
- 最终窗口已复验滚动条隐藏（`.never`）；只滚动左配置，不改变右预览。保存前后截图及[像素比较结果](skin-native/fixed-preview.json)已归档：左侧区域像素变化，右侧预览区域差异为 `null`。
- 修改英文字体为 Menlo，保存后核对独立 `settings.json`，再次打开编辑器显示 Menlo；保存状态为「已保存」。编辑后的字体随预览生效。
- 前一轮窗口已检查新建、添加深色、保存为用户主题、改单色后关闭出现未保存确认并选择继续编辑；Claude 浅色和深色均在真实窗口查看。
- 导出对话框能打开；主题文件往返与图片校验由自动化覆盖，未完成所有系统文件对话框及菜单交互的 GUI 矩阵。

[一级页面截图](skin-native/catalog.jpg) · [编辑页顶部截图](skin-native/editor-top.jpg) · [左侧滚动后截图](skin-native/editor-scrolled.jpg)

## 尚未验收

真实输入源的系统外观切换、热更新、背景图逐键性能／内存、宿主焦点矩阵及完整发布验证尚未执行；不能用设置窗口或离屏绘制结果替代。未做 Windows 皮肤页面、主题包双击关联、外置图片资源／平铺／九宫格。未执行安装或重启输入法。
