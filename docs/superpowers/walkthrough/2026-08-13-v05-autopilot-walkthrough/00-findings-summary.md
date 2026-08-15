# Agent Arena v0.5 设计走查 — 发现汇总与裁定（多专家 + debate）

> 走查对象：v0.5 提案（human/auto 双模式 + autopilot 外部编排层）。输入：`input-design.md`。
> 方法：5 位专家角色（security / statemachine / sre / product / qa）按 SDD 三轮白板走查（R1 用户故事/AC、R2 技术追踪/契约、R3 集成/错误）独立评审 + 主持人交叉辩论与裁定。
> 基线：v0.4 已发布（50 节 hermetic 全绿、真实 Cursor 冒烟完成）；v0.5 核心承诺="状态机不动、审计链不变、v0.4 测试零语义漂移"。

## 参与专家与统计

| 专家 | 严重 | 主要 | 次要 | 信息 | 合计 | 文档 |
|---|---|---|---|---|---|---|
| security（安全/审批） | 2 | 7 | 1 | 3 | 13 | expert-security.md |
| statemachine（状态机/并发） | 2 | 6 | 5 | 2 | 15 | expert-statemachine.md |
| sre（无人值守运维） | 3 | 9 | 4 | 1 | 17 | expert-sre.md |
| product（产品/工作流） | 3 | 4 | 3 | 2 | 12 | expert-product.md |
| qa（测试/质量） | 2 | 5 | 5 | 3 | 15 | expert-qa.md |
| **合计** | **12** | **31** | **18** | **11** | **72** | |

## 总体结论

**方向成立**：5/5 专家一致确认"状态机不动 + autopilot 外部编排 + opt-in 默认 human"是正确架构（T10 guard 天然吸收并发竞态，autopilot 只是 resolve 的普通调用方）。但草案有 **4 个阻塞级缺陷**必须在 spec 前修复（见下），且"无人值守推进到完成"的承诺必须收敛为"APPROVE+PASS 路径自动完成 + 其余路径 stop-and-alarm（不静默）"。

## 阻塞级发现与裁定（严重，12 条去重后核心 7 条）

| # | 发现 | 来源 | 裁定 |
|---|---|---|---|
| B1 | **actor=autopilot 与 v0.4 wire contract 冲突**：`last_transition_actor` 枚举仅 writer/reviewer/human/system，读取端对枚举外值 fail-closed 判损坏（0.4.0 会把 v0.5 状态判为 corrupted）；且 resolve.sh 硬编码 actor='human'、approve 清空 reason_detail | security S2、qa QA-01 | **零契约变更方案**：autopilot 调 resolve 时 actor=**system**（枚举已含）、action 保持 **resolve-approve**（枚举已含，已核实 state.sh L108-109）、`--reason "autopilot <instance-token> <scan-ts>"` 写入 reason_detail（resolve approve 分支改为"有 --reason 就保留"）。0.4.0 可读回 v0.5 状态，rollback 语义不破坏 |
| B2 | **`--once` 退出码 2 与 v0.4 协议语义碰撞**（v0.4 中 2=非法转移/损坏，草案中 2=需人工介入），且无聚合优先级 | statemachine R2-1、qa QA-06 | **分配新码 6=需人工介入**（避开 0/1/2/3/4/5/10）；autopilot 专属协议表：0=无动作、4=锁竞争（defer 不报警）、5=incomplete、6=需人工；优先级 6>5>4>0（镜像 list 聚合模型）；预期竞态（状态已变/锁瞬时占用）只记日志不进退出码 |
| B3 | **动作矩阵缺 pane 活性维度**：reviewer/writer pane 死亡不改变状态，最常见的无人值守故障（模型 pane 死）在状态机里不可见，任务无限期静默停摆 | sre 严重、product R1-5、qa QA-02 | 扫描升级为 **state × pane-liveness 二维**：submitted/validated + reviewer pane dead → 自动 escalate（T9 合法）或报警；changes_requested + writer pane dead → 报警；WAITING_SINCE 停滞超阈值（per-state 默认，如 review_pending>30min）→ 报警 |
| B4 | **lib/lock.sh dead-PID 回收存在互斥破坏竞态**（rm -rf+mkdir 两步，双回收者可同时成功）+ PID 复用使死锁永久"活"；watch+cron 并发后窗口放大，AC6"单实例"不成立 | statemachine R2-2/R2-3 | **v0.5 Task 0 前置修复**：回收改原子 **rename-to-tombstone**（mv 成功者重建）；autopilot 锁 owner 记录 last_seen_at，活性判定=pid alive AND last_seen 新鲜（<3×interval）；新增双实例并发回收 fixture |
| B5 | **mode 无运行期切换路径**：start 一次性快照后，"下班放手/上班接管/重要 run 收回人工"核心工作流不可达 | product R1-1 | **新增 `mode RUN_ID human|auto` 命令**（受 run lock 保护，记录 actor/时间，status 显示最近切换）；同时保持"配置漂移不静默生效"：manifest mode ≠ project.conf 时 status/list 显示漂移标记 ⚠（security M1） |
| B6 | **relay 提醒无节流**：超时条件每轮成立，watch 每 30s 向 writer pane send-keys，模型 mid-turn 被打断是确定性副作用 | product R3-1、sre、statemachine R3-3、qa QA-07 | per-run 观测 `last_relay_at`（放 autopilot 观测，零状态机影响），冷却期内不重发；默认值 pin：`--interval 30`、`--relay-after 30`（分钟）；消息带 `[autopilot]` 前缀；同 run 同原因重复提醒记 `skipped (throttled)` |
| B7 | **完成边界未定义**：Arena completed ≠ 代码交付（无 merge/push），operator 会误以为"活干完了" | sre 严重 | AC 显式声明完成边界（v0.5 的"完成"=状态 completed，交付/合并为范围外）；README 非承诺表加一行 |

## 主要发现采纳清单（共识，31 条去重后核心）

- **承诺收敛**（statemachine R1-1、qa QA-05、product R1-2）：auto 模式 = 自动完成 APPROVE+PASS 路径 + 其余 stop-and-alarm；AC 措辞两段式契约
- **扫描走 `status` oracle 为唯一读入口**（statemachine R3-5）：exit 4=defer 下轮重扫；S1-S6 意图阶段与 legacy run 跳过
- **心跳并入锁活性 + 每实例一行**（statemachine R2-3、sre）：autopilot.tsv 每实例（host:pid:nonce）一行；钉死为观测文件，永不参与状态机判定
- **动作日志权威边界**（statemachine R3-2、sre）：autopilot.log/tsv 是 best-effort 观测；权威=run-state + SHA 决策归档；reason 带实例标识使 日志↔心跳↔state 三元可关联
- **作用域白名单**（security M3、product R2-2）：默认当前 repo；`--all-repos` 显式开启并记录扫描范围
- **approve 冷却窗口**（security M2）：`--approve-delay` 默认 5 分钟，decision→approve 最小间隔记入日志
- **mode 入 creation intent 绑定**（statemachine R2-5）：中断 start 后 mode 变更的重试 fail-closed
- **relay/报警与审批模式解耦**（product R1-3）：human 模式同样可提醒/报警（exit 6）；human 模式下 approval_pending 归入"需人工介入"
- **run 级显式 opt-in**（security S1）：`start --mode auto` 或 init TTY 确认，而非仅 project.conf 一个键（防静默 uncomment）
- **exit 4 语义**（statemachine R2-4）：扫描遇 live lock = defer，不计数不报警
- **状态×模式×动作全量真值表**（qa QA-02）：14 状态 × 2 模式穷举，default=只观测零副作用
- **AC 命名空间 v05-ACn**（qa QA-04），避免与 v0.4 AC1-13 撞号
- **"50 节零改动"→"零语义漂移 + N 处显式断言更新清单"**（qa QA-03）：config 严格解析不能丢
- **完成边界/时钟跳变/sleep 行为**（sre）：staleness 判定容忍抖动，文档化接受的操作风险
- **--once stdout per-run TSV 摘要**（product R3-3、qa）：run_id/mode/state/action/result，与 autopilot.log 同构

## 冲突点裁决（debate 焦点）

| 冲突 | 正方 | 反方 | 裁定 |
|---|---|---|---|
| **决策点 A：list 加 MODE 列？** | product/security/sre：list 是无人值守 dashboard，mode 是"找谁处理"第一信息 | statemachine/qa：v0.4 row contract 是钉死契约，为展示字段改权威契约性价比最低；status Mode 行已覆盖 | **不加**（2:3 反方胜，理由=契约纪律 + 与 v0.5"命令语义不动"原则一致）；operator 的 dashboard 需求由 `autopilot --once` 的 per-run TSV 摘要（含 mode 列）满足；list 扩展列为 **v0.6 显式 contract 升级项**（追加列只能放末尾、不参与 composite-key、独立迁移提交） |
| **actor 契约：扩展枚举 vs system 复用** | qa：枚举扩展（状态文件是执行者单一事实源） | security：system+reason 零契约变更 | **system 复用**（B1 裁定）：0.4.0 兼容回读 > 执行者粒度；粒度由 reason 实例标识 + autopilot.log 补足 |
| **mode 切换 vs 不可变** | product：必须运行期切换 | statemachine：run 级不可变语义应显式声明 | **显式切换命令 + 默认不可变**（B5 裁定）：切换是受锁保护的显式操作（审计可追溯）；配置漂移不自动改 mode，只显示 ⚠ |
| **--once 退出码：新码 6 vs 复用 2** | qa：autopilot 专属表 0/2/4/5 | statemachine：避开 2 用 6 | **新码 6**（B2 裁定）：全仓唯一解释，与 v0.4 协议零碰撞 |
| **resume 自动重试（决策点 B）** | — | 5/5 一致：默认 0 只报警 | **默认 0**（全票）：trust prompt 需人工是实测事实，自动 resume 只制造"假活" pane；启用时 spawn 记 unconfirmed 并触发 exit 6；"gate trust 免人工预授权"列为 v0.6 前置项 |

## 修订后的 v0.5 范围（吸收全部裁定）

```
Task 0  锁回收原子化修复（rename-to-tombstone + last_seen 心跳 + 双实例 fixture）
Task 1  mode 配置与契约：project.conf approval_mode + manifest mode 字段 +
        mode RUN_ID human|auto 切换命令 + status Mode 行 + 漂移标记 ⚠ +
        mode 入 creation intent 绑定（v05-AC1/AC8）
Task 2  resolve 审计透传：--actor system|human（默认 human）+ approve 保留 --reason
        （actor=system / action=resolve-approve / reason 带 autopilot 实例标识）
Task 3  autopilot 核心：--once/--watch、state×pane 二维扫描（status oracle 读入口）、
        动作矩阵（approval_pending→approve 带 --approve-delay；reviewer pane dead→
        escalate/报警；writer pane dead→报警；停滞→报警）、exit 6 协议、
        --repo 白名单（v05-AC2/AC3/AC4/AC6/AC7）
Task 4  观测与审计：autopilot.tsv 每实例一行（last_seen 并入锁活性）、
        autopilot.log（result 分类：acted/deferred/benign-race/needs-human/error）、
        relay 节流 last_relay_at（v05-AC5/AC9/AC10）
Task 5  文档与回归：spec review-ready、README 非承诺表（完成边界/信任模型降级）、
        v0.4 50 节"零语义漂移+N 处断言更新"核对表、新增 §50-53（v05-AC11）
```

## 决策点最终裁定

- **A（list MODE 列）：不加**。status Mode 行 + `--once` TSV 摘要覆盖；v0.6 显式 contract 升级。
- **B（resume 默认）：0 只报警**（5/5 全票）。启用时 spawn 记 unconfirmed 并 exit 6。

## 一句话

"状态机不动 + autopilot 外置 + opt-in"架构获全票通过；草案的 4 个阻塞点（actor 契约、退出码碰撞、pane 活性缺失、锁回收竞态）均有零契约变更或前置修复的裁定路径；**auto 模式的能力承诺 = APPROVE+PASS 自动完成 + 全停滞路径报警，不是任务自愈**。

## 走查文档

- [Round 1 — 用户故事/AC 聚合](01-round1-user-stories.md)
- [Round 2 — 技术追踪/契约聚合](02-round2-technical-trace.md)
- [Round 3 — 集成/错误聚合](03-round3-integration-check.md)
- 专家原文：expert-security.md / expert-statemachine.md / expert-sre.md / expert-product.md / expert-qa.md
