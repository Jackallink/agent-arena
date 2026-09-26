# Round 3 — 集成与错误

- 走查轮次: 3/3 · 日期 2026-09-26 · 只引用 01/02 的 ID，不重写
- 范围: Round 2 闭合后的跨边界行为——E2E 矩阵、错误矩阵、幂等/重复、一致性核对

## 1. E2E 矩阵（主链 + 物质异常）

| # | 场景 | 链路 | 端到端断言 |
|---|---|---|---|
| IT-001 | 全流水线主链（happy） | start → stage intent(F1 输入) → accept → stage spec → accept → stage plan → accept → bootstrap(F3) → writer checkpoint 含 `docs/arena/<run-id>/`(P-017) → submit → validate → decide | 每步 hint 正确(F2)；snapshot 含 plan(AC-10)；manifest 有完整 stage_* 链 |
| IT-002 | lean 流水线（intent only） | start --pipeline lean → stage intent → accept → bootstrap | bootstrap 只 seed intent.md；writer prompt 只注入 intent |
| IT-003 | from-intent 入口（非工程师） | start --from-intent → 发起人自审 → accept → … | 无 agent 会话发生在 accept 前（AC-08） |
| IT-004 | 拒绝循环 | accept 前提坏 → reject("缺风险段") → stage 重生成 prompt 含 summary → accept | attempts 计数 +1；旧 digest 被 manifest 锁定不被覆盖丢失 |
| IT-005 | stage 失败留置 | 会话 exit 3 / 无 draft → S3 → 人查 sessions/ → 重试 stage → 成功 | 锁释放正确；S3 在 TUI 按 needs-human 排序 |
| IT-006 | 生成中 cancel | S1 持锁 → cancel kill PID(F11) → 锁回收 → run dir 移除 | repo 零残留；intent/ 入口原文件保留 |
| IT-007 | 无配置回归 | 无 roles.conf → v0.6 全流程 | AC-01 字节等价 |
| IT-008 | TUI 向导 | n → 输入 → confirm argv → spawn → 列表出现新 run | 两段 spawn（start+stage）时 session 名/顺序正确 |

## 2. 错误矩阵（failure → 用户可见结果 / 客户端行为）

| 条件 | 用户可见 | 退出码 | 客户端/下游行为 |
|---|---|---|---|
| roles.conf 未知键/adapter/缺 prompt | `roles.conf:LINE: reason` | 1 | fail fast；doctor 亦可探出（P-014） |
| `stage` 与 phase 不符 | `phase=X, stage must be Y` | 1 | hint 当前可用命令 |
| intent 无 prompt 输入（F1） | `stage intent requires --prompt-text or --prompt-file` | 1 | — |
| `--from-intent` 空/超 64KB/非 UTF-8 | 带原因+文件路径 | 1 | — |
| accept 时 draft 缺失 / stage≠phase | 带 run_dir 路径 / `phase=X, cannot accept Y` | 1 | — |
| stage 会话非零/无产物 | status: `stage_failed` + 原因；list --json: reason_code | 0（收割命令本身成功） | TUI needs-human-first（party=human） |
| 活锁并发 stage/cancel | `locked by PID N (owner alive)` | 1 | 提示重试或 kill+cancel(F11) |
| 死锁回收（F4） | stderr 注 `recovered stale stage lock (PID N)` | 继续 | attempts 不变（非新会话开始前审计） |
| sandbox-exec 缺失/注入失败 | 大写降级警告 + manifest `stage_<s>_sandbox=soft` | 0 | doctor 报 ready=soft |
| `--pipeline` 未知 stage 名 | 带合法值列表 | 1 | — |
| manifest 新键被 v0.6 工具读 | 人读 status 忽略未知键（现有行为） | — | JSON 消费者 `#[serde(default)]` |
| 沙箱内写 run dir 外 | agent 侧 `Operation not permitted` | 会话自述失败 | 属 IT-005 链路，S3 收割 |

## 3. 幂等 / 重复 / 一致性核对

- **双 accept**：第二次 accept 在 phase 已推进后触发 `stage≠phase` 守卫 → 拒绝。✓
- **重复 stage**：S2 期再 stage（draft 已存在）→ 允许（覆盖旧 draft=重新生成语义，与 P-004 一致）；S1 期 → 锁拒绝。✓
- **cancel ×2**：第二次走现有"run 不存在"路径。✓
- **幂等 seed**：bootstrap 重入（理论上不可能，末 accept 单次）→ copy 目标存在则跳过。防御性 ✓
- **与既有模式一致性**：manifest 平铺键、`arena_die` 1 退出、list --json exit==human exit、TUI 薄客户端（spawn 面=bin/agent-arena+tmux，未新增可执行）、destructive 不映射（n 向导只 spawn start+stage）。✓
- **审计一致性**：sessions/ stdout 留档 + stage_* manifest 链 + docs/arena/<run-id>/ repo 落地 = 三层证据（playbook commit-chain 对应物）。✓

## 4. 未决项（owner + status）

| ID | 项 | Owner | 状态 |
|---|---|---|---|
| F10 | draft authorship 字段 | Arena backlog | deferred（digest 回放比对足够） |
| F8 | `config --json` oracle（TUI 预填） | Arena backlog | deferred v0.8 |
| — | Gate 0 spike：`zell -p` × `--session-id/--session-dir` 组合 | 本实现者 | **实现前必做**（spec §14 已列） |
| — | bwrap Linux 对应物 | Arena backlog | deferred（spec §3 已注） |
| jihulab 325 | zell `-nbt` 语义 | zell 上游 | 不阻塞（`--no-extensions` 恒传） |

## 5. Exit 自查

- [x] 主链 + 物质异常的 E2E 矩阵（IT-001–IT-008）
- [x] 错误矩阵含用户可见结果与客户端行为
- [x] 幂等/重复/权限/一致性核对（§3）
- [x] 未决项全部有 owner + 状态；无 Severe/Major 遗留（F1–F11 已决议或 deferred 为 Minor）
- [x] 阻塞项仅剩 Gate 0 spike（外部事实核验，非设计缺口）
