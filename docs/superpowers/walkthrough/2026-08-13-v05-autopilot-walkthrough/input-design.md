# v0.5 走查输入：human/auto 双模式 + autopilot 设计草案

> 评审对象：Agent Arena v0.5 提案。请各专家角色按 SDD 三轮白板走查（R1 用户故事/AC、R2 技术追踪/契约状态、R3 集成/错误）审查本草案，输出发现与建议。

## 0. 背景与目标

v0.4（已发布 0.4.0）实现了 run state authority：per-run `run-state.tsv` 单一事实源、T1–T14 全转移矩阵、escalate/resolve/repair-state、run lock、legacy 投影、status/list oracle、退出码 0/1/2/3/4/5/10。评审环（writer 提交 → reviewer 自动 validate+decision）已被真实 Cursor 冒烟验证可全自动；但任务"完全无人参与地推进到完成"有两个设计断点：decision APPROVE 后卡在 approval_pending 等 human resolve；escalate/BLOCKED 必须人工；writer 继续工作无调度驱动（relay best-effort）。

**v0.5 目标**：引入 human approve / auto 双模式开关，使"有人值守"与"无人值守自动推进"两种场景都被覆盖，且不破坏 v0.4 的审计链与 50 节 hermetic 测试。

## 1. v0.4 现状事实（评审依据）

- 状态机：start(T1)→submit(T2/T3/T4)→validate(T5)→decision(T6–T8)→resolve(T9–T13)→completed；escalate→blocked；repair-state(T14)。所有迁移在 `.run-lock` 下原子提交（owner 元数据、60s grace、dead-PID 恢复）。
- decision APPROVE → `active/decided/human/approval_pending`；必须 `resolve --action approve` 才 `completed`。resolve 是 human 命令（AC6），执行者记录 last_transition_actor。
- relay：writer/reviewer 双向 tmux 消息，**best-effort**（README 明示 "tmux cannot know whether an interactive model is mid-turn"）。
- resume：respawn 死掉的 reviewer pane；**真实环境会弹 trust prompt，需人工确认**（v0.4 冒烟实测）。
- list 固定列：`REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY REASON_CODE WAITING_SINCE AUTHORITY ANOMALY`（v0.4 spec 钉死）。
- status：零写入 oracle，一句话诊断 + 退出码协议（0/1/2/3/4/5/10）。
- 审计：SHA 绑定 decision/validation 记录为权威；manifest/run-state 在私有 state root（默认 ~/.local/state/agent-arena）。
- 配置：`project.conf`（init 生成，目前含 project_name/validation_script）。
- 约束：Bash 3.2 兼容、hermetic 测试（tests/run.sh 50 节，fake CLI、临时 git、私有 tmux socket、不调模型/网络）、SDD/TDD（先 spec 后实现）、AGENTS.md 安全 handoff。

## 2. v0.5 设计草案

### 核心决策：状态机不动，autopilot 在外部执行

auto 模式 = opt-in 配置 + autopilot 编排层，**不修改 v0.4 T 矩阵/命令语义**。auto approve 的审计链：autopilot 执行 `resolve --action approve --reason "autopilot ..."`，actor=autopilot，SHA 决策记录不变。

### 2.1 模式开关

- `project.conf` 新增 `approval_mode=human|auto`（opt-in，默认 human；init 生成时注释风险）。
- `start` 时写入 run manifest 的 `mode` 字段（旧 manifest 无字段 = human，向后兼容）。
- `status` 输出加 `Mode: auto|human` 行。list 列：**决策点 A**（见 §4）。

### 2.2 autopilot 命令

```
agent-arena autopilot [--once] [--interval 30] [--resume-attempts N] [--relay-after MIN]
```

- `--watch`（默认）常驻循环；`--once` 单轮（cron/launchd 友好）。
- 每轮扫描每个 run（读 mode），动作矩阵：

| 状态 | auto 模式 | human 模式 |
|---|---|---|
| active/decided/human/approval_pending（APPROVE+PASS） | 自动 resolve approve | 只观测 |
| active/writer/changes_requested 超时（>relay-after） | relay 提醒 writer（best-effort） | 只观测 |
| blocked/human/reviewer_unreachable | 可选自动 resume（--resume-attempts，默认 0=关） | 只报警 |
| blocked/human/block_resolution_required | 永不自动（等 human） | 只报警 |
| completed/canceled | 跳过 | — |
| corrupt/conflict/incomplete | 记录错误，聚合退出码 | 同左 |

### 2.3 可观测性与审计

- 心跳：state root `autopilot.tsv`（last_scan_at/scanned/acted/errors/按 mode 汇总）。
- 动作日志：`autopilot.log`（append-only TSV：timestamp run_id action result）。
- `--once` 退出码：0=正常；2=发现需人工介入（blocked 等），供 cron 报警。

### 2.4 安全护栏（AC 级）

1. auto 必须显式配置（opt-in）；init 默认 human。
2. auto approve 仅当 verdict=APPROVE 且 validation=PASS（状态机 guard 保证）。
3. cancel/reject 永不自动；BLOCKED 只报警。
4. 无 --force/--yolo 类绕过；autopilot 自身有锁（复用 lib/lock.sh，防多实例并发）。
5. resume 默认关闭（trust prompt 需人工确认是 v0.4 实测事实）。

### 2.5 范围（AC 草案）

- AC1 mode 配置解析 + manifest 落档 + status 显示
- AC2 autopilot --once：auto 模式自动 approve（actor 审计、幂等）
- AC3 autopilot human 模式只观测不动作
- AC4 blocked 报警 + 永不自动 cancel；corrupt/conflict 聚合退出码
- AC5 心跳 autopilot.tsv + 动作日志
- AC6 autopilot 自身锁（单实例）
- AC7 全量回归（v0.4 50 节零改动 + 新增 §50–53）

### 2.6 文件

新建 `lib/autopilot.sh`；改 `lib/config.sh`、`lib/start.sh`（manifest mode）、`lib/status.sh`（Mode 行）、`lib/arena.sh`（dispatch）、`tests/run.sh`（§50–53）。版本 0.5.0。

## 3. 已知风险（供专家挑战）

- auto approve 滥用：同 UID 下任何能跑 agent-arena 的进程都能开 autopilot（v0.4 F5 威胁模型：writer 同 UID 可伪造，靠 prompt 约束）——auto 模式是否放大该威胁？
- autopilot 与 reviewer/writer 模型并发：模型正在 pane 里工作时 autopilot 执行 resolve 是否安全（resolve 有 run lock + 状态 guard）？
- relay 提醒 best-effort：changes_requested 提醒可能丢失，writer 无人响应时任务仍会停住——"无人值守"承诺是否过度？
- 常驻 watch 与 cron --once 双跑：锁是否足够？
- 心跳文件语义：autopilot.tsv 是观测文件还是权威？崩溃后恢复？

## 4. 待定决策点（请各专家表态 + 理由）

- **A：list 是否加 MODE 列？**（保持 v0.4 row contract 不变 / 升级 contract 追加列并同步改 spec+测试）
- **B：resume 自动重试默认值？**（默认 0=只报警 / 默认 1 次尝试后报警）

## 5. 评审要求（各专家输出格式）

请在你的评审文档中：
1. 按 R1/R2/R3 三个焦点给出发现（每条：级别【严重/主要/次要/信息】+ 发现 + 证据/推理 + 建议）。
2. 对设计草案最尖锐的 3 个质疑（哪怕你觉得设计没问题也要挑）。
3. 对决策点 A/B 表态 + 理由。
4. 一句话总结：这个设计方向是否成立，最大风险是什么。
