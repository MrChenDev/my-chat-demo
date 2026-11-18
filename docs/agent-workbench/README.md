# DeepSeek Chat V1 与后续 DSH 集成方案

本目录记录先完善并独立发布 chat-demo、再逐步接入 DeepSeek Harness 的产品和架构提案。当前均为草案，供用户验收；验收前不开始实现产品功能。

## 文档

1. [产品需求方案（PRD）](./PRD.md)：定位、用户流程、功能/非功能需求、MVP 范围和验收标准。
2. [架构与开发方案](./ARCHITECTURE-AND-DEV-PLAN.md)：V1 Chat 边界、未来 Adapter 接口、DSH 集成路线、仓库边界、阶段计划、验证与风险。

## 本轮建议结论

- **V1 先把 chat-demo 做好并独立发布**，用户无需安装或运行 DSH。
- V1 只预留小型、版本化的 Agent Adapter/DTO 边界；不做 DSH Host 调用、模式切换、交接界面或 Agent Recent。
- Chat 核心不依赖 DSH 包和 Session 格式；不合并两仓库，也不修改 DSH 核心。
- V1 发布后再做 DSH Profile/插件 POC，届时决定使用 DSH Web 插件、最小通用 UI 扩展或独立 Workbench Shell。
- V1 发布模式与 API Key 责任边界需产品验收；托管 API Key 需要独立的后端和安全方案。

官方产品参考显示，ChatGPT 桌面端统一提供 ChatGPT/Codex 入口，但 Codex 历史仍与 ChatGPT 分开；OpenAI 对应用集成的建议也强调应用 UI/上下文与 Agent Harness 的分层。详见 [架构方案](./ARCHITECTURE-AND-DEV-PLAN.md#1-架构结论摘要)。
