# v0.5 走查 Round 3 — 集成与错误（多专家聚合）

> 各专家完整论证见 expert-*.md 的 R3 节。

## 关键发现

| # | 级别 | 发现 | 来源 | 裁定 |
|---|---|---|---|---|
| B6 | 严重 | relay 提醒无节流：超时条件每轮成立 → 30s 刷屏 writer pane | product R3-1 / sre R1-3 / statemachine R3-3 / qa QA-07 | last_relay_at 冷却（默认 30min）+ [autopilot] 前缀 + skipped (throttled) 日志 |
| B3 | 严重 | pane 活性维度缺失（集成视角：resume best-effort 后 reviewer 死掉不 escalate 则静默） | sre / qa QA-02 | 二维扫描：pane dead → escalate/报警；停滞阈值报警 |
| — | 主要 | operator 无知情/接管优先权：30s 轮询可能抢先于人工 | product R3-2 | --approve-delay 冷却窗口（默认 5min）+ 切换命令即接管机制 |
| — | 主要 | --once 退出码二分不足 + stdout 无 per-run 摘要 | product R3-3 / qa | exit 6 + per-run TSV 摘要（cron 可解析） |
| — | 主要 | watch 挂死 → cron --once 永久 exit 4，监控死循环 | sre R2-1 | last_seen 锁活性 + 僵尸锁接管（B4 裁定） |
| — | 主要 | watch+cron 双跑"谁该干活"未定义 | sre R2-2 / product R3-4 | 主运行者约定 + 双实例 exit 4 输出 pid + 文档化二选一 |
| — | 主要 | 动作日志崩溃窗口（resolve 已提交、日志未 append） | statemachine R3-2 | 日志=观测；reason 实例标识三元关联 |
| — | 次要 | 审计权威边界（日志可丢、审计不丢） | statemachine R3-2 | 同上 |
| — | 次要 | 时钟跳变/sleep 导致超时误判、日志无轮转 | sre R1-5 | 容忍区间 + 文档化 + log 上限轮转 |
| — | 次要 | mode 漂移（config 中途改）在集成期显示 | security M1 | ⚠ 标记 |
| — | 次要 | 全量真值表（14 状态 × 2 模式）default=只观测 | qa QA-02 | spec 附录 |
| — | 信息 | --once 输出与 autopilot.log 同构便于 cron | product R3-3 | 采纳 |

## 集成测试矩阵（新增 §50–53 草案）

- §50 mode 配置/切换/漂移（含 creation intent 绑定拒绝、严格 parser 保持）
- §51 autopilot --once auto：approve 闭环 + actor=system + reason 断言 + 幂等（良性竞态只记日志）
- §52 human 模式零动作 + 可报警（exit 6）；blocked/cancel 永不自动
- §53 心跳/锁：每实例行、last_seen 新鲜度、双实例并发回收 fixture、relay 节流、--approve-delay
