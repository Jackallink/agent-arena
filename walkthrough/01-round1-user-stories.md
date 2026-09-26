# Round 1 — 用户故事与验收标准

- 特性: v0.7 Multi-Stage Artifact Pipeline (intent → spec → plan → implementation)
- 来源 spec: `docs/superpowers/specs/2026-09-26-artifact-pipeline.md` (7260f3b + e7e2392)
- 走查轮次: 1/3 · 日期 2026-09-26

## 1. 范围

**IN**
- 三个上游 artifact 阶段（intent/spec/plan）：headless agent 会话生成、人工 accept/reject gate、SHA 锁定、digest 进 manifest
- roles.conf 两级配置（全局默认 + 项目覆盖）+ `--pipeline` CLI 覆盖
- OS 沙箱（macOS seatbelt）包裹 stage 会话；缺失时降级警告
- 人工可编辑 draft；accept 对磁盘实际内容哈希
- writer 首个 checkpoint 携带 `docs/arena/<run-id>/` 进 repo
- TUI `n` 向导 + pipeline run 的列表呈现/排序
- JSON v1 additive-only 兼容
- cancel/escalate/resolve/lock 覆盖新 phase

**OUT**
- 运行中切换 writer/agent/model（证据链不可变，N2）
- 维护闭环（breached control band → 新 intent，v0.8，N3）
- 跨 stage 自动回跳（N4）；stage 会话的 tmux 交互 pane（N5）
- pi/zell 参数级沙箱（上游 jihulab 325 不阻塞；工具名门控已够）
- Deploy/Maintain 阶段（playbook 六阶段中 Arena v0.7 只做到 Build 前置）

## 2. 用户路径目录（P-ID）

| P-ID | 路径 | 主角色 | 优先级 |
|---|---|---|---|
| P-001 | 配置 roles.conf（全局 → 项目覆盖 → 校验） | 项目配置者 | 必达 |
| P-002 | 全流水线 run：start → intent → spec → plan → implementation → 现有 gate 循环 | 需求发起人 + 守门人 | 必达 |
| P-003 | 从 repo `intent/` 入口：`start --from-intent FILE` | 需求发起人（可非工程师） | 必达 |
| P-004 | gate 拒绝某 stage → 同 stage 重生成（reject summary 注入重试 prompt） | 守门人 | 必达 |
| P-005 | 人工编辑 draft 文件后 accept（哈希磁盘实况） | 守门人 | 期望 |
| P-006 | TUI `n` 向导建 run（pipeline 深度 + per-stage model 覆盖） | TUI 操作者 | 期望 |
| P-007 | TUI 列表查看/排序 pipeline run（needs-human-first 适用新 phase） | TUI 操作者 | 期望 |
| P-008 | stage 生成期间并发 stage/cancel 被 lock 拒绝 | 任意 | 期望 |
| P-009 | 任意 stage phase 上 cancel（run dir 移除，repo 零残留） | 任意 | 必达 |
| P-010 | 新 phase 上的 escalate/resolve 覆盖 | 守门人 | 期望 |
| P-011 | 无 sandbox-exec 环境降级（大声警告 + 软约束继续） | 配置者 | 期望 |
| P-012 | 无 roles.conf ⇒ v0.6 行为字节级不变 | 既有用户 | 必达 |
| P-013 | roles.conf 解析错误 fail fast（路径+行号） | 配置者 | 必达 |
| P-014 | adapter 未声明 headless_stage ⇒ stage 跳过 + doctor 警告 | 配置者 | 期望 |
| P-015 | `--pipeline` 覆盖 config（none/lean/full/显式列表） | 高级用户 | 期望 |
| P-016 | stage 会话失败（非零退出/无产出/超时） | 守门人 | 必达 |
| P-017 | writer 首个 checkpoint 携带 accepted artifacts（reviewer snapshot 含 plan） | reviewer | 必达 |
| P-018 | JSON/TUI 消费者对 v0.6-shaped 与 pipeline-shaped runs 的兼容 | 集成消费者 | 必达 |

## 3. 用户故事

| US-ID | 故事 | 覆盖路径 |
|---|---|---|
| US-001 | 作为项目配置者，我要为每个 stage 配置 {adapter, model, prompt} 并获得解析/可用性反馈，以便流水线按项目裁剪 | P-001, P-013, P-014 |
| US-002 | 作为需求发起人，我要用自己的话发起一个 run（口述文本或 intent/ 文件），让 agent 把它加工成可审阅的 intent.md | P-002, P-003 |
| US-003 | 作为守门人，我要审阅每个 stage 的产物并 accept/reject/编辑后再 accept，reject 的理由要进下一轮生成 | P-004, P-005 |
| US-004 | 作为 reviewer，我要在 detached snapshot 里拿到已批准的 plan.md，以便把 diff 对照 plan 审查 | P-017 |
| US-005 | 作为 TUI 操作者，我要用向导一步建起带 pipeline 的 run，并在列表里看清每个 run 走到哪个 artifact | P-006, P-007 |
| US-006 | 作为集成消费者（脚本/TUI/Rust model），我要 schema 1 的既有字段与退出码不变，新增字段可安全忽略 | P-018 |
| US-007 | 作为运维者，我要能从任何 stage 干净地取消/升级/恢复 run，且生成期间有并发保护 | P-008, P-009, P-010, P-016 |

## 4. 验收标准（Given / When / Then）

P0/P-001 全部可测。`spec` 列 = 来源 spec §12 的 AC 编号映射。

| AC-ID  优先级 | Given / When / Then | spec | 路径 |
|---|---|---|---|---|
| AC-01  必达 | G 任意环境无 roles.conf / W 走完 v0.6 全流程（start→submit→validate→decide） / T manifest 无 pipeline 键、人读输出与 JSON 与 v0.6 字节一致、退出码一致 | AC1 | P-012 |
| AC-02  必达 | G run 处于 intent phase 且 intent-draft.md 存在 / W `artifact RUN --stage intent --accept` / T 文件改名 intent.md、manifest 记录 {digest(sha256), accepted_at, agent, model}、phase 推进到下一启用 stage（无则为 implementation 就绪） | AC4 | P-002 |
| AC-03  必达 | G 同 AC-02 / W `artifact RUN --stage intent --reject --summary "缺风险段"` / T draft 保留、reject 记录入 manifest、phase 留在 intent、下次 stage 生成的 prompt 含 summary | AC4 | P-004 |
| AC-04  必达 | G 守门人在生成与 accept 之间编辑了 draft / W `--accept` / T digest 是磁盘实况的哈希（编辑被接受为证据一部分） | AC4 | P-005 |
| AC-05  必达 | G run 在任意 stage phase（含 generating lock 持有中） / W `cancel RUN` / T run dir 整体移除、repo 无任何残留（untracked intent/ 原文件除外——它是入口不是产物） | AC10 | P-009 |
| AC-06  必达 | G stage 会话正在生成（lock 持有） / W 并发 `stage RUN <s>` 或 `cancel` / T 第二个调用被拒且提示锁持有者；锁随会话退出释放（含失败退出） | AC4, AC10 | P-008, P-016 |
| AC-07  必达 | G stage 会话非零退出或未产出 draft / W Arena 收割会话结果 / T run 不进 accept 态：phase 留在本 stage、manifest 记录失败原因（退出码/无产物）、lock 释放、可重试 `stage` | **gap→F1** | P-016 |
| AC-08  必达 | G repo `intent/foo.md` 存在 / W `start RUN --repo P --from-intent intent/foo.md` / T 文件复制为 run 内 intent-draft.md、phase=intent、party=human、不启动 agent 会话（发起人自审） | AC5 | P-003 |
| AC-09  必达 | G plan 已 accept / W implementation 启动（writer worktree 创建 + writer spawn） / T worktree 内出现 unstaged `docs/arena/<run-id>/{intent,spec,plan}.md`（按已 accept 的集合）、writer system prompt 注入这些路径 | AC6 | P-017 |
| AC-10  必达 | G pipeline 模式 run 走到 reviewer / W snapshot 生成 / T reviewer 收到的 detached snapshot 含 plan.md（diff 对照审查的前提） | AC6 | P-017 |
| AC-11  必达 | G roles.conf 含 unknown key / 未知 adapter / 缺失 prompt 文件 / W 任一命令读配置 / T fail fast，错误含 conf 路径+行号+原因 | AC2 | P-013 |
| AC-12  必达 | G v0.6-shaped manifest / W `list --json`、`status RUN --json` / T 输出与 v0.6 字节一致；pipeline-shaped run 输出仅 additive 字段（pipeline 数组/块），Rust `#[serde(default)]` 解析两者 | AC9 | P-018 |
| AC-13  期望 | G 全局与项目 roles.conf 各定义部分 stage / W 配置解析 / T 逐 key 项目覆盖全局、未定义 stage 跳过、最终 pipeline = 启用的 stage 序列 | AC2 | P-001 |
| AC-14  期望 | G `stage RUN <s>` / W spawn / T argv 合同：sandbox-exec 包裹 + adapter headless 模式 + `--tools read,write` + `--no-extensions` + session id/dir + model 透传 + append-system-prompt（模板+context.md） | AC3 | P-002 |
| AC-15  期望 | G 本机无 sandbox-exec（或注入失败） / W stage 生成 / T 输出显著降级警告、会话照常运行（软约束）、不静默 | AC7 | P-011 |
| AC-16  期望 | G macOS 有 sandbox-exec / W 沙箱内探针写 run dir 外路径 / T 写被 OS 拒（`Operation not permitted`）、run dir 内写成功 | AC7 | P-002 |
| AC-17  期望 | G TUI 焦点在 run 列表 / W 按 `n` / T 依次输入 run_id/repo/profile/pipeline 深度(per-stage model 默认自 roles.conf 可发现时)→confirm 行 verbatim argv→spawn start；任意步 `q`/`Esc` 干净取消 | AC8 | P-006 |
| AC-18  期望 | G 存在 pipeline-shaped run（含 awaiting_stage_accept 的） / W 列表渲染+排序 / T phase 列显示 artifact stage、party=human 的 run 按 needs-human-first 排序、`n` 加入 keymap 合同（其余键不变） | AC8 | P-007 |
| AC-19  期望 | G roles.conf 定义了 adapter 未声明 headless_stage 的 stage / W doctor + start / T 该 stage 跳过（pipeline 收缩）+ doctor 警告列明 adapter 与缺失声明 | **gap→F5** | P-014 |
| AC-20  期望 | G `--pipeline` 显式给定（none/lean/full/逗号列表） / W start / T 覆盖 conf 结果、`--pipeline none` = 纯 v0.6 流程（与 AC-01 等价行为） | AC1 | P-015 |
| AC-21  期望 | G 新 phase 上的 run 卡死/需要人工接管 / W escalate / resolve / T 与现有语义一致地工作（escalate reason-code 集合或明确不支持并给出替代路径） | AC10 | P-010 |

### Live gate（不可 hermetic，spec §12 Live 行）
- L1 真实 zell `-p` 完成 intent→spec→plan 全链（scratch repo）；L2 人工 gate 全走 CLI；L3 writer（真实 zell）首个 commit 携带 `docs/arena/<run-id>/`；L4 TUI 向导建 lean-pipeline run 并走完。

## 5. 边界与异常路径清单（检查覆盖）

- 空/缺：draft 不存在时 accept（AC-02 前置破坏）→ 必须报错而非空哈希 **→ F6**；intent/ 入口文件为空/超大的处理 **→ F7**
- 非法：accept 的 stage 与当前 phase 不符（如 intent 期 accept spec）→ 必须拒绝 **→ F6**；`--pipeline` 含未知 stage 名 → fail fast
- 取消/权限：P-009/P-008 已列；stage 会话被外部 kill（SIGKILL 无清理）→ lock 陈旧回收策略 **→ F4**
- 并发：同一 run 双 accept；不同 run 并行 stage（应允许，锁粒度=run）
- 兼容：v0.6 工具链读新 manifest（人类可读 status 不因未知键崩溃）

## 6. Findings（严重度排序，Severe/Major 阻塞实现）

| ID | 严重度 | 发现 | 建议处置 |
|---|---|---|---|
| F1 | **Severe** | intent 生成的用户原始需求文本无 CLI 承载：`stage RUN intent` 的 spawn 协议有 `<stage instruction>` 占位（§9），但 `stage RUN <stage>` 命令签名（§10）无输入参数；P-002 口述需求进不了系统（P-003 文件入口除外） | Round 2 定：`stage RUN <s> [--prompt-text T \| --prompt-file F]` 或 `start --intent-text`；TUI 向导同步 |
| F2 | Major | accept → 下一 stage 的触发语义未定义（手动 `stage` vs 自动连锁）。playbook 核心是 "accepted artifact fires the next gate"，spec 决策 5 又说 merge 触发=Arena 状态机——两处张力 | Round 2 定：建议 accept 后自动 spawn 下一 stage（状态机即编排），reject/取消可中断；或 accept 输出下一步命令 hint（保守） |
| F3 | Major | pipeline 模式下 start 的时序未定义：worktree/writer spawn 是 start 时一次完成（现状）还是 plan accept 后才建？§7.3 "implementation 开始时 seeded" 暗示后者 → start 拆两步，dirty-check/锁语义全部受影响 | Round 2 技术走查必答（P-002 主链路） |
| F4 | Major | stage 会话被 SIGKILL/机器重启后 lock 陈旧：无回收策略则 run 永久卡在 generating | Round 2 定：lock 带 PID+时间戳，`stage` 重入时检测持有者已死则回收 |
| F5 | Minor | "adapter 未声明 headless_stage ⇒ stage skipped" 的 AC 只在 spec 隐含（§8 末段），spec §12 表无对应行；AC-19 补齐 | spec 增补 AC 行 + 测试映射 |
| F6 | Minor | accept 的防御性边界（draft 缺失、stage 与 phase 不符）spec 未写明；空 draft 哈希空文件是错误行为 | spec §7.2 增补两条拒绝条件；AC 表已列（AC-02/05 前置） |
| F7 | Minor | `--from-intent` 文件为空/超大/非 UTF-8 未定义 | Round 2 定上限（如 64KB）与错误消息 |
| F8 | Minor | TUI 向导 "per-stage model overrides defaulted from roles.conf when discoverable" —— discoverable 语义模糊（TUI 是薄客户端，读 conf 需新 oracle 或仅提示） | Round 2 定：新增 `config --json` oracle 或向导不预填（输入自由文本） |

## 7. Round 2 输入问题清单

1. F1：intent 输入通道的 CLI 形态（决定 P-002 是否成立）
2. F2：accept 后自动 vs 手动 spawn 下一 stage
3. F3：start 两步化的状态机/锁/dirty-check 影响面
4. F4：lock 陈旧回收（PID 存活探测）
5. F7/F6：入口文件与 accept 的防御性校验清单
6. `stage` 失败重试是否计次/封顶（agent 烧钱循环）

## 8. Exit 自查

- [x] 范围 IN/OUT 显式（§1）
- [x] 全部已知用户路径编号（18 条 P-ID）
- [x] P0/P-001 AC 均为 Given/When/Then 可测（21 条 + 4 条 Live）
- [x] 未知技术事实记为 Round 2 问题（§7），未在本轮做组件设计
- [x] Severe/Major findings 前置（F1 阻塞实现，须在 Round 2 闭合）
