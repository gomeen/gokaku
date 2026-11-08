# Windows b98 组合与首键修复及限定回归

本轮连续交付三个修复，均以正式安装件在同版本链路上复测。版本 `0.1.1-dev.2 / b98 / dev`。完整 Windows 宿主、安装回滚／卸载及朋友真机验收仍需单列完成。

## 三个修复

1. **旧组合跨字段提交资格**（b95 引入）：宿主终止组合时撤销代理旧资格、更新字段身份；Chromium 等临时文本存储只在候选窗显示编码，选词才写正文。说明与复现见 [b95 记录](../dev-b95-fix/README.md)。
2. **InputScope 滞后吞首键**（b97 引入，b98 复测）：宿主复用 TSF 上下文切换 DOM 字段时，新字段的 InputScope 可能延迟生效；首次读取若为「允许」，40ms 后复核一次，不一致则本键放行（可见可恢复，不吞字）。读取瞬时失败沿用上一键结论，保证 Test 与 KeyDown 决策一致；仍失败按拒绝处理。
   - 失败证据：[b96 密码轮 `ihc `](b96-observation/chrome-password-failure.json)（N 被误认领吞掉）。
   - 修复后：b98 密码 3/3 通过 `nihc `。
3. **调频落盘阻塞请求路径**（b98 引入）：代理每 30 秒在全局锁内做模型序列化＋写盘，打字中恰逢落盘会让 TSF 的 200ms 截止超时；按键已进代理却被按「未吃键」放行，宿主重复出字。改为管道空闲超过 3 秒才落盘（活跃输入顺延），单键截止放宽到 400ms。
   - 失败证据：[b97 chrome-basic `hc你好`](b97-observation/chrome-basic-1-failure.json)（H、C 同时进正文与代理，最终提交「你好」）。
   - 修复后：b98 chrome-basic 4/4 通过「你好」。

## 正式包与验证

- [fast 7/7](build/report-fast-dev-b98.json)；[ASan／UBSan quick](build/report-asan-ubsan-quick-dev-b98.json) 2,000 序列通过（整体 release gate 仍未通过，不代表十万序列）。
- Windows EXE SHA-256：`368021b37e7b7c013507129d014a2476b53f6741d0c223e63e0c40d2ee0547ab`；Mac PKG 仅构建未安装。
- [安装记录](install.json)：默认升级返回 0，71 个文件与双架构 COM 匹配，上一根指向 b97，未指定 `/DIR`。
- [组合生命周期回归](composition/b98-x64.json)／[x86](composition/b98-x86.json)：每架构两条路径通过。

## 限定矩阵 13/13（正式 b98 DLL＋b98 代理）

两次 Chrome 切框、四个新宿主首组「你好」、三次密码 `nihc `、记事本两次暖启动与两次代理缺席后的新进程首组「你好」。逐轮模块身份为 b98、内存 PE timestamp `1794123559`；[逐轮证据](cases/)与[汇总](matrix-summary.json)。冷启动第 2 轮复活的代理已独立核验哈希与 b98 清单一致；第 1 轮代理路径仅由夹具记录，行为一致。

历史失败继续保留：[b95 首轮混合旧代理 `i` 残留](../dev-b95-fix/README.md)未逐例归因；本轮两个新失败（b96、b97）已分别修复并复测，不宣称覆盖全部历史个案。

## 环境观察：旧代理复活

VM 上仍有宿主驻留旧版 TSF DLL（explorer.exe 持有 b91 时代的 `C:\gogaku-test\GogakuTsf.dll`，msedge.exe 持有 b97 DLL）。这些宿主的连接定时器会在管道消失时按**自己模块路径**复活旧代理——这正是 b95 轮「b95 DLL＋长期运行 b94 代理」混合态的成因。当前运行的 b98 代理持有互斥量期间，僵尸代理立即退出，无法夺走管道；仅在冷启动「停止自有代理→激活」的窗口存在竞态。夹具已放宽为停止全部 `GogakuDev` 自有代理并复查复活（[夹具](reproducer/host-acceptance.cpp)、[切换脚本](reproducer/ensure-agent.ps1)）。旧宿主需重开后才会换用新 DLL；升级不改默认输入法、不强杀宿主。

## 复现源码

[host-acceptance.cpp](reproducer/host-acceptance.cpp) 与 [helpers.cpp](reproducer/helpers.cpp)／[browser-cases.h](reproducer/browser-cases.h) 保留合成页面、焦点、逐键与模块证据：

```sh
x86_64-w64-mingw32-g++ -std=c++17 -O2 -static -municode -mwindows \
  -I shared/third_party \
  docs/validation/dev-b98-fix/reproducer/host-acceptance.cpp \
  -o HostAcceptance.exe -lgdiplus -lgdi32 -lole32 -loleaut32 -luuid -lcomctl32 -lwinhttp
```

只在已授权且空闲的 Windows 桌面运行；夹具创建专属测试文档并发送真实按键。组合回归用 `python3 probes/build-windows-composition-lifecycle.py` 构建（只编译，复制到 Windows 分别运行 x64／x86）。[清理脚本](reproducer/cleanup98.py)核对正式注册、代理与临时任务移除。

## 验证边界

完整验收仍未通过：Windows Terminal／Electron／真实 32 位应用矩阵、性能 p95 与长时稳定性、真实翻译与在线更新、安装故障恢复／卸载、Mac b98 实装均未完成。macOS clangd 无 Windows SDK 头文件路径，静态诊断不可用；实际 MinGW 双架构编译与 Windows 回归另列。证据链与身份见[汇总](../dev-b98-fix.json)。
