# 05 WebP 随包解码（主题包）

Status: ready-for-agent

来源：[实施计划](../../../docs/implementation-plan.md)「设置、皮肤与拼写」；[功能对照](../../../docs/feature-parity.md)「背景图片与主题包」行。

## 背景

主题包 ZIP v1 容器校验已双端实现，Windows 走 WIC 解码 PNG／JPEG／WebP，但 WebP 依赖系统 codec——缺失环境下主题包不可用，行为不等价。主题包容器解析目前仍在两端各算一层（契约抽取后续项）。

## 验收标准

- 随包固定 WebP 解码器（核对许可证并署名，流程同 HarfBuzz／FreeType／libpng／zlib 先例），不依赖系统 codec。
- 两端对同一组主题包样本（PNG／JPEG／WebP，含损坏样本）得出相同结论——按「共享实现规则」入库对拍向量；至少主题包容器解析层收敛为共享实现。
- 缺字体回退行为不变。
