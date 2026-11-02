# 本目录为中止的运行（2026-11-02 16:38 启动）

开发节奏调整：十万序列 ASan 耗时约 2 小时，阻塞迭代，于 17:26 主动中止（fuzz 进程被终止，
无最终报告）。已通过项（version／resources／core-tests／swift-tests／clean-build／bundle／
quality 109+112／render 51 项／data-reliability 40 轮）的日志在本目录保留，仅作过程证据，
不作为该轮发布门槛通过依据。

替代记录：
- ASan 冒烟：report-release-20261102-172641.json（--quick 2000 序列，注明不满足十万门槛）
- 完整十万序列：由 17:29 重新启动的全量档补跑归档（见后续 report-release-*.json）
