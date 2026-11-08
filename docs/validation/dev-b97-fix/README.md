# Windows b97（InputScope 复核）——当日被 b98 取代

b97 引入「首次安全判定为允许时 40ms 复核」与「读取瞬时失败沿用上一键结论」，修复 b96 密码轮的首键吞噬（`ihc `）。复测中发现了第二个独立缺陷：代理调频落盘持全局锁阻塞请求，`hc你好` 重复出字（见 [b96/b97 观察与修复](../dev-b98-fix/README.md)）。b98 当日叠加落盘让路与 400ms 截止并完成 13 轮矩阵，故 b97 不再单独交付。

本目录保留 b97 的原始证据：

- [安装记录](install.json)、[代理切换](state/ensure-agent97.json)、[身份核对](state/identity97-verify-pre.json)、[用户数据基线](state/state97-after-install.json)。
- [b96 观察证据](b96-observation/)：6 轮通过与密码失败原件。
- [构建材料](build/)：b97 fast 7/7 与 ASan quick。
- [组合生命周期回归](../dev-b98-fix/composition/)与最终矩阵在 [b98 记录](../dev-b98-fix/README.md)。

b97 的 Windows EXE（SHA-256 `eca196c93e20916ea1f96c7a740fbbcb2619e72d58fcf1263a1672be8b65edbc`）与 Mac PKG 未再作为交付物引用；对外以 b98 为准。
