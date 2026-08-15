# Agent Arena

> **一句话：** Agent Arena 把两个不同来源的 AI agent（一个**写代码**、一个**评审**）
> 放进完全隔离的工作区，自动协作完成"写码 → 提交 → 验证 → 决策 → 批准"的可审计闭环；
> 支持**人工/自动双模式**，有人值守或无人值守都能安全推进。

Agent Arena 是一个本地优先、独立的终端工作流：一个编码 writer + 一个独立的
评审/验证/决策 gate。`tmuxp` 创建四个面板；Git worktree 隔离交接；`tmux`
在 agent 之间直接中转短消息。

## 核心价值

- **自带模型，自由组合** —— 任意 writer（Pi / Codex / OpenCode / Agy）搭配任意
  正式 gate（Cursor / OpenCode）；已用真实 Pi writer + 真实 Cursor reviewer
  端到端 live 验证（2026-08-15）。
- **隔离是设计出来的** —— 每次 run 拥有独立 Git worktree 和 tmux 会话；评审
  快照是 detached HEAD，任何污染都会被完整性检查检出。
- **审计真相，不是聊天记录** —— SHA 绑定的验证报告与决策记录是权威；
  `run-state.tsv` 回答"下一个是谁、在等什么、等了多久、怎么释放"。
- **有人值守或无人值守** —— `human` 模式保留人工批准环节；`auto` 模式 +
  `autopilot` 让顺利路径无人值守完成，并对每条停滞路径报警（exit 6）。
- **崩溃可恢复** —— creation/repair intent 让中断的转移可重试；旧版本 run
  只读投影、首次写入时迁移。
- **质量门禁** —— 56 节 hermetic 测试、tmuxp/CLI 契约/打包检查、每次发布前
  的真实 CLI 冒烟证据。

每个 profile 组合一个 writer 与一个 gate。**Cursor Agent** 是默认的正式
评审/验证/决策 gate；`--gate opencode` 或 `WRITER-GATE` profile（如
`pi-opencode`）选择 OpenCode gate。Pi、Codex、OpenCode、Agy 仅作 writer。
relay 消息是便利反馈，但 SHA 绑定的验证报告与决策记录才是审计真相。

> **验证状态：** v0.5.1 具备 hermetic 适配器测试（56 节 —— v0.4 §0–49 零语义
> 漂移 + autopilot §50–55）、tmuxp 冒烟、无模型 CLI 契约检查，以及真实 CLI
> 冒烟：2026-08-15 记录了一次完整双模型无人值守闭环（真实 Pi writer → 真实
> Cursor reviewer → autopilot 自动批准）。已记录一处 drift（D5）：在 agent
> 2026.08.11 下，shell 重定向写（`echo x > file`）绕过 Cursor 沙箱拒绝；
> 运行后快照完整性检查会检出此类污染，审计链保持关闭。`doctor` 只确认本地
> 前置条件，不验证 provider 侧行为。

## 位置模型

```text
~/.local/state/agent-arena/          run 状态与审计记录（私有）
<项目>/.agent-arena/                 项目适配器（project.conf + validate.sh）
<项目>/../arena-worktrees/           每个 run 的 writer/reviewer worktree
```

## 快速开始

```bash
# 1. 项目接入
cd /path/to/project
agent-arena init
# 编辑 .agent-arena/validate.sh 为项目的确定性检查

# 2. 启动一个 run（Pi 写 + Cursor 审）
agent-arena start RUN_ID --repo /path/to/project

# 3. writer 提交 checkpoint 后，由 writer 提交评审
agent-arena submit RUN_ID

# 4. reviewer（Cursor）在快照里执行 gate wrapper：
#    ./.agent-arena-gate validate RUN_ID
#    ./.agent-arena-gate decision RUN_ID --verdict APPROVE --summary ... --next ...

# 5. 人工批准（human 模式，默认）
agent-arena resolve RUN_ID --action approve

# 或者：无人值守（auto 模式）
#    project.conf 里 approval_mode="auto"（或 start --mode auto）
#    agent-arena autopilot --watch     # 常驻
#    agent-arena autopilot --once      # cron 单轮
```

## Writer profiles 与限制

| profile | writer | gate |
|---|---|---|
| pi-cursor（默认） | Pi | Cursor |
| codex-cursor | Codex | Cursor |
| opencode-cursor | OpenCode | Cursor |
| agy-cursor | Agy | Cursor |
| pi-opencode | Pi | OpenCode |
| ... | 任意 writer | opencode |

writer 只被允许在隔离 worktree 内工作，禁止编辑集成工作树、merge、push、
reset、fetch 或使用危险绕过标志。gate 是唯一能对快照做正式裁决的角色。

### Gates

- **Cursor（默认）**：交互式正式 gate；policy 为 deny-first allowlist，
  只允许 `Read(**)` 与 gate wrapper 命令。
- **OpenCode**：备用 gate，生成的 `opencode.json` 策略同样 deny-first。
- Codex / Agy 不可作为 gate（无项目级策略文件 / 策略为全局）。

## 命令

```bash
agent-arena doctor
agent-arena init --repo /path/to/project
agent-arena start RUN_ID --repo /path/to/project
agent-arena submit RUN_ID
agent-arena validate RUN_ID
agent-arena decision RUN_ID --verdict APPROVE --summary "..." --next "..."
agent-arena relay RUN_ID --to writer --from reviewer --message "..."
agent-arena escalate RUN_ID --reason-code reviewer_unreachable --reason "..."
agent-arena resolve RUN_ID --action approve|reject|recover|cancel --reason "..."
agent-arena repair-state RUN_ID --candidate TOKEN --reason "..."
agent-arena mode RUN_ID human|auto
agent-arena autopilot [options]
agent-arena status RUN_ID
agent-arena list
```

## Run state（运行状态权威）

自 v0.4 起，每个 run 携带 `run-state.tsv`，作为"下一个是谁、在等什么、从何时
开始等、如何释放"的单一事实源。既有证据文件（review.tsv、验证报告、决策
记录）仍是流程证据，但不再反向推导责任。

`status RUN_ID` 是只读 oracle：打印 manifest、绑定证据与一句话诊断，例如：

```
waiting on reviewer for review_pending since 1786781395; tmux session: not running; release: agent-arena validate or-run
```

`list` 打印固定列 —— `REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY
REASON_CODE WAITING_SINCE AUTHORITY ANOMALY` —— `AUTHORITY` 为 `state`（权威
v1 行）或 `legacy`（只读投影）。两个 oracle 均零写入；`status` 对损坏状态或
证据冲突 fail-closed（exit 2）；`list` 按优先级 `5 > 4 > 2 > 0` 聚合异常码。

### 人工命令

- `escalate RUN_ID --reason-code reviewer_unreachable --reason "..."`：把卡住的
  run（reviewer 责任、`submitted`/`validated`）升级到人工责任（`blocked`）。
- `resolve RUN_ID --action approve|reject|recover|cancel --reason "..."`：人工
  处置。`approve` 完成 reviewer 的 `APPROVE`；`reject` 退回；`recover` 在
  reviewer 面板恢复后解除升级；`cancel` 放弃 run。
- `repair-state RUN_ID --candidate TOKEN --reason "..."`：接受 `status` 打印的
  修复候选（legacy 证据冲突或损坏状态）。token 绑定证据摘要与状态基线，过期/
  外部 token 被拒绝；修复 intent-first、崩溃可恢复。

### 退出码

`0` 正常 · `1` 用法错误 · `2` 状态损坏或证据冲突 · `3` 验证 CAS 基线过期 ·
`4` 活动锁 / 转移进行中 · `5` 未完成转移，按提示重试 · `10` 验证记录 FAIL。

## Autopilot 与审批模式

自 v0.5 起每个 run 携带审批模式（`human` 默认 / `auto`），由 `start` 从
`project.conf` 的 `approval_mode` 快照（可用 `start --mode auto` 覆盖），运行期
用 `agent-arena mode RUN_ID human|auto` 切换（加锁、审计、终态拒绝）。
`status` 显示 `Mode:`，配置与 manifest 漂移时显示 `(config: ...) ⚠`。

```
agent-arena autopilot [--once] [--interval 30] [--approve-delay 300]
                       [--relay-after 30] [--resume-attempts 0]
                       [--repo PATH] [--all-repos] [--rounds N]
```

- **auto 模式**：`decided/human/approval_pending` + `APPROVE` + `PASS` 的 run，
  在冷却窗口（`--approve-delay`）后自动批准，记录 `last_transition_actor=system`
  与携带 autopilot 实例 token 的 reason。
- **每条停滞路径都报警**：`--once` 退出码 `0`（一切正常）/ `4`（另一 autopilot
  持锁，watch 与 cron 并存时正常）/ `6`（需要人工：待批准、阻塞、面板死、
  停滞、损坏）。
- 评审面板死亡在 `submitted`/`validated` 时自动 escalate（T9）；评审停滞
  （> 30 分钟）报警；停滞的 writer 在 `--relay-after` 窗口内最多收到一次
  `[autopilot]` 提醒。
- **部署**：有人值守用 `autopilot --watch`；无人值守用 cron `autopilot --once`；
  避免两者并存（后者 exit 4）。
- **观测（非权威）**：`autopilot.tsv`（每实例心跳行）、`autopilot.log`
  （追加式动作日志，1 MB 轮转）、`autopilot-throttle.tsv`。审计链仍是
  `run-state.tsv` + SHA 绑定记录。

**非承诺：** autopilot 不交付代码（`completed` 是 Arena 状态，不是
merge/push）、不唤醒 writer（提醒是 best-effort）、不绕过 trust prompt、
绝不 cancel/reject。`auto` 模式是信任模型降级（唯一的非 AI 批准环节被自动化）
——只为验证脚本严格、风险低的仓库开启。

## 正式 gate 适配器

Cursor 保持默认正式 gate，以正常交互模式运行，只允许调用生成的 gate wrapper
的 `validate`/`decision`/`relay`/`status`。不使用 `--force`、`--yolo` 或计划
模式。可用 `--gate` 或 `WRITER-GATE` profile 选择 gate；`cursor` 与 `opencode`
自带适配器。版本 0.1 起拒绝跟踪 `.cursor/cli.json` 或 `.agent-arena-gate` 的
checkpoint：无法证明 Cursor 的数组分层同时保留项目策略与 Arena 的 deny-first
gate。请保持这些路径不跟踪。依赖 gate 前，请阅读实施计划中记录的真实 Cursor
冒烟。截至 2026-08-15（Cursor agent 2026.08.11），deny-first 策略在交互路径
拦截列出的 Shell 命令，但 shell 重定向写（`echo x > file`）在 `--sandbox
enabled` 下可绕过 `Write(**)`/`Shell(echo *)` 拒绝（drift D5）；运行后快照
完整性检查会检出此类污染并关闭验证/决策审计链。

## 恢复与清理

Agent Arena 从不 fetch、stash、reset、merge、push 或删除 worktree。`list`
显示每个已记录 run 及其派生状态。手动恢复要点：

- 被意外删除的评审快照会在下次 `submit` 自动重建（过期 worktree 注册会被
  prune，绝不丢数据）。
- 崩溃或手动删除留下的孤儿 worktree 注册可用 `git worktree prune` 清理；
  Arena 从不删除 run 状态与会话日志。
- 孤儿 writer 分支可在确认无 run manifest 引用后 `git branch -D
  agent-arena/<adapter>/<run_id>` 删除。
- 中断的 `start` 可能留下无 tmux 会话的 run 目录；重跑 `start` 恢复。

## License

本项目采用 [MIT License](LICENSE)。允许公开源码；发布 GitHub Release 或
软件包仍需要文档化的 Gate 4 证据。

## 文档导航

- v0.5 autopilot 规格与计划：`docs/superpowers/specs/2026-08-13-autopilot-approval-mode.md`
- v0.4 run state 规格与计划：`docs/superpowers/specs/2026-08-13-run-state-authority.md`
- 多专家走查（v0.5）：`docs/superpowers/walkthrough/2026-08-13-v05-autopilot-walkthrough/`
