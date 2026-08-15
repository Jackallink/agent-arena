# v0.5 spec 评审任务书（Gate 1 第二轮）

> 评审对象已从"设计草案"升级为**正式 spec**：
> `/Users/jakeliu/Workspace/agent-arena/docs/superpowers/specs/2026-08-13-autopilot-approval-mode.md`
> 配套材料：
> - 实施计划：`docs/superpowers/plans/2026-08-13-autopilot-approval-mode.md`
> - 走查裁定来源：`docs/superpowers/walkthrough/2026-08-13-v05-autopilot-walkthrough/00-findings-summary.md`（B1–B7、决策点 A/B、主要采纳清单）
> - v0.4 现状：`docs/superpowers/specs/2026-08-13-run-state-authority.md` + `lib/*.sh` 源码

## 本轮评审的四个核心问题（请逐条回答）

1. **裁定忠实度**：spec 是否完整、无走样地落地了 00-findings-summary 的全部裁定？
   逐条核对：B1（actor=system+reason 透传）、B2（exit 6 新码）、B3（pane 活性二维）、
   B4（锁回收原子化）、B5（mode 切换命令+漂移标记）、B6（relay 节流）、B7（完成边界）、
   决策点 A（list 不加列）、决策点 B（resume 默认 0）、承诺收敛（auto=approve 自动+stop-and-alarm）、
   观测文件非权威、扫描走 status oracle、--repo 白名单、--approve-delay、intent 绑定、AC 命名空间。
   发现任何遗漏/走样/新增未裁定设计，请指出。

2. **spec 质量**（gate 1 标准）：
   - 每条 v05-AC 是否可写 hermetic 测试？（指出测不出来的 AC）
   - 契约是否无歧义：字段/标志/默认值/退出码/文件 schema 是否全部 pin 死？
   - 有无"实现时必然要再问一次"的开放问题？
   - 与 v0.4 的一致性：有无隐性破坏（哪怕一处输出/解析/错误信息变化导致 v0.4 测试受影响）？

3. **可行性**：Bash 3.2 + fake CLI 环境下，autopilot 的实现与测试是否可行？
   pane 活性维度在 fake tmux 下能否可靠测试？--watch 常驻进程如何 hermetic 测试？

4. **裁决投票**（三选一，给出理由）：
   - GATE-1 PASS：可进入实现（Task 0–5）
   - CONDITIONAL PASS：列出必改项（阻塞级）与建议项（非阻塞）
   - FAIL：需重写 spec（指出方向性错误）

## 输出

评审文档写入：`docs/superpowers/walkthrough/2026-08-13-v05-autopilot-walkthrough/spec-review-<role>.md`
（中文，按四个问题组织；发现用【严重/主要/次要/信息】分级）。
完成后 agent_message.send 给 parent 发送：裁决投票 + 必改项数量 + 最关键 1 个问题。
