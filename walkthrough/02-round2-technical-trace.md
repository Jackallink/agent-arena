# Round 2 — 技术追踪

- 走查轮次: 2/3 · 日期 2026-09-26 · 基线: 01-round1（P-ID/AC-ID 不重复，只引用）
- 代码基线: 60a629c..93cba36（state.sh phase 校验 L91、lock.sh `arena_lock_owner_alive` L22、start.sh 一次性 bootstrap）

## 0. Round 1 缺口闭合决议（F1–F8）

| ID | 决议（进 spec 修订） |
|---|---|
| F1 (Severe) | `stage RUN <s> [--prompt-text T \| --prompt-file F]`：intent 阶段二者必居其一（spec 阶段起非必需——前序 artifact 即输入）；TUI 向导把用户输入写临时文件走 `--prompt-file` |
| F2 | **手动触发，accept 给 hint**：`artifact --accept` 推进 phase 并在 stdout 末尾打印下一命令（`arena stage RUN spec` 或 implementation 提示）。不自动 spawn——每次 agent 消耗都是人触发的（与 submit 由 writer 显式调用同一原则）；"状态机即触发簿记"落在 phase 推进 + hint |
| F3 | **plan accept 触发 implementation bootstrap**：start.sh 现有 worktree 创建/dirty-check/单写者断言抽成 `arena_implementation_bootstrap RUN`；pipeline 模式 start 只建 run+state（phase=首个 stage）；最后一个 stage accept 后调 bootstrap（worktree 创建 + artifact seeding + writer spawn + phase→intake）。dirty-check 移到 bootstrap 时刻（start 与 plan accept 间隔数小时，晚检查更正确）。非 pipeline（v0.6）路径行为不变 |
| F4 | 复用 lock.sh `arena_lock_owner_alive`：stage 会话持锁（owner=PID+token）；`stage` 重入遇死 owner → 回收锁 + manifest 记 `stage_<s>_recovered_at`，继续生成。活 owner → AC-006 拒绝 |
| F6 | `artifact --accept` 守卫：draft 缺失 → exit 1（含 run_dir 路径）；stage ≠ 当前 phase → exit 1（`phase=X, cannot accept Y`） |
| F7 | `--from-intent` 校验：非空、≤64KB、UTF-8（`iconv -f UTF-8 -t UTF-8` 探针）→ 违例 exit 1 带原因 |
| F8 | v0.7 向导**不预填** model：hint 行显示 roles.conf 路径，输入自由文本；`config --json` oracle 记 backlog |
| 重试封顶 | 无自动重试（每次 stage 都是人工触发）→ 无烧钱循环，不加计数封顶；`stage_<s>_attempts` 仅审计记录 |
| F5 | spec §12 增补 AC11（adapter 无 headless_stage → 跳过+doctor 警告）→ 对应走查 AC-019 |

## 1. 状态目录（新增契约）

**state.sh phase 枚举扩容**（L91）: `intent|spec|plan` 插在 intake 前；plan accept 后 → `intake`（= 现有 writer 工作期，零语义变更）。party/reason_code 新增组合：

| 状态 | phase | party | reason_code | waiting_since |
|---|---|---|---|---|
| S1 stage 生成中 | intent/spec/plan | none | stage_generating | — |
| S2 等 gate | intent/spec/plan | human | awaiting_stage_accept | ✓（TUI needs-human-first 直接生效） |
| S3 失败留置 | intent/spec/plan | human | stage_failed | ✓ |

**manifest 新键**（平铺，与现有风格一致）: `pipeline`（逗号串）、每 s∈pipeline: `stage_<s>_status{pending,generating,awaiting_accept,accepted,failed}`、`stage_<s>_draft`、`stage_<s>_digest`、`stage_<s>_accepted_at`、`stage_<s>_agent`、`stage_<s>_model`、`stage_<s>_attempts`、`stage_<s>_reject_summary`（最近一次）。

## 2. CLI 目录（API 合同）

| ID | 命令 | API 合同 |
|---|---|---|
| C1 | `start RUN --repo P [--from-intent F] [--pipeline LIST]` | pipeline 模式：只建 run_dir+state（phase=首 stage、party=human/S2 若 from-intent，否则等 `stage` 触发生成）；非 pipeline：现行为逐字节不变 |
| C2 | `stage RUN <s> [--prompt-text T \| --prompt-file F]` | s 必须=当前 phase；intent 需 prompt 输入；持锁 spawn（§3 spawn 链）；S1→S2/失败→S3 |
| C3 | `artifact RUN --stage <s> --accept \| --reject --summary "..."` | accept: 守卫(F6)→sha256→改名→S2 推进→末 stage 则 bootstrap(F3)→hint(F2)；reject: 记录+留 draft+保持 phase |
| C4 | `list/status [--json]` | additive: row/fields 增 `pipeline`；schema 仍 1 |

## 3. 逐路径追踪（引用 §0–§2 目录）

- **P-001 配置**: Handler/组件: `lib/roles_conf.sh: arena_roles_load`（start/stage/artifact/doctor 调用）→ 状态: 内存 pipeline+per-stage 配置（manifest 在 start 时落 `pipeline` 键）→ API: 失败 `roles.conf:LINE: reason` exit 1 → 后端: 全局→项目逐 key 覆盖、未知 adapter/prompt 缺失校验 → UI/响应: 成功静默，doctor 增 advisory 段（AC-011/013）
- **P-002 全流水线**: Handler/组件: `lib/stage.sh`（新）+ `lib/artifact.sh`（新）+ `arena_implementation_bootstrap` → 状态: S2(intent)→S2(spec)→S2(plan)→intake，逐 stage manifest 键 → API: C1→C2(intent, --prompt-file)→C3 循环→C2/C3 至 plan → 后端: sandbox-exec 包裹 zell -p（argv=AC-014）→收割→bootstrap（dirty-check→worktree→seed `docs/arena/<run-id>/`→spawn writer）→ UI/响应: 每次 accept 尾部 hint 下一命令（F2）；TUI phase 列渲染（AC-002/009, L1）
- **P-003 from-intent**: Handler/组件: `lib/start.sh` 入口分支 → 状态: 复制为 intent-draft.md、phase=intent、party=human（无 agent 会话）→ API: C1 `--from-intent`，F7 校验（非空/≤64KB/UTF-8）→ 后端: 文件复制到 run dir → UI/响应: `artifact --accept` 或先手编提示（AC-008）
- **P-004 拒绝重生成**: Handler/组件: `lib/artifact.sh` reject 分支 + stage.sh prompt 组装 → 状态: manifest 记 reject_summary、draft 保留、phase 留 S2 → API: C3 `--reject --summary` → 后端: 重生成 prompt 注入 `先前被拒理由: <summary>`（模板占位符），旧 draft 覆盖（digest 已锁定）→ UI/响应: TUI reason_code=awaiting_stage_accept（AC-003）
- **P-005 编辑后 accept**: Handler/组件: 守门人 vi draft + artifact.sh accept → 状态: digest=磁盘实况 sha256 → API: C3 --accept → 后端: 哈希时点在 accept 执行时 → UI/响应: manifest 记录可回放（AC-004；authorship=F10 deferred）
- **P-006 TUI n 向导**: Handler/组件: `ui/src/main.rs` InputMode 序列 + model.rs PromptKind → 状态: 无（spawn 后由 list --json 反映）→ API: spawn `bin/agent-arena start ...`（+`stage --prompt-file`，intent 文本经临时文件）→ 后端: confirm 行 verbatim argv→y→spawn → UI/响应: 输入提示逐字段、任意步 q/Esc 取消（AC-017）
- **P-007 TUI 列表**: Handler/组件: `lib/list.sh` row 构造 + `ui/src/model.rs` sort_runs → 状态: S2 行 party=human → API: C4 增 `pipeline` 字段（additive）→ 后端: `#[serde(default)] pipeline: Vec<String>` → UI/响应: phase 列显示 intent/spec/plan；needs-human-first 无改动生效（AC-012/018）
- **P-008 并发/锁**: Handler/组件: `lib/lock.sh`（复用）+ stage.sh/cancel 调用点 → 状态: 锁 owner=PID+token；S1 期再入被拒 → API: exit 1 `locked by PID N (owner alive)` → 后端: 死 owner 回收（`arena_lock_owner_alive` 探测）+ manifest `stage_<s>_recovered_at` → UI/响应: stderr 提示重试或 cancel kill（AC-006）
- **P-009 cancel**: Handler/组件: 现有 cancel 路径 + 未 bootstrap 分支跳过 worktree 清理 → 状态: run dir 移除、repo 零残留 → API: 现有 cancel 命令 → 后端: 持锁 stage 会话 PID 被 kill（F11 特权）→ UI/响应: intent/ 入口原文件保留（AC-005）
- **P-010 escalate/resolve**: Handler/组件: 现有 escalate/resolve 无改动 → 状态: S3 失败留置 party=human → API: reason-code 集合不扩（F9 文档化：stage 卡死 → cancel 或 kill+锁回收）→ 后端: 无新逻辑 → UI/响应: 文档与 doctor 提示对应（AC-021 走查弱化版）
- **P-011 沙箱降级**: Handler/组件: stage.sh spawn 前探针 → 状态: manifest `stage_<s>_sandbox=soft` → API: 无新参数 → 后端: `command -v sandbox-exec` 缺失/注入失败 → 照常 spawn → UI/响应: stderr 大写降级警告，不静默；doctor 报 soft（AC-015）
- **P-012 无配置回归**: Handler/组件: roles_conf load 空结果 → start.sh v0.6 分支 → 状态: 无 pipeline 键 → API: 现命令面 → 后端: bootstrap=旧 start 内联路径 → UI/响应: 字节等价由 §62 回归锁死（AC-001/020）
- **P-013 配置错误**: Handler/组件: `lib/roles_conf.sh: arena_roles_load` fail-fast → 状态: 无（拒绝时命令不继续）→ API: exit 1 带 conf 路径+行号+原因 → 后端: 未知键/未知 adapter/缺 prompt 三类校验 → UI/响应: 错误消息直接可行动（AC-011）
- **P-014 doctor**: Handler/组件: `lib/doctor.sh` advisory 段 → 状态: 只读探查，无状态变更 → API: 现有 doctor 命令面不变 → 后端: 列 roles.conf 摘要、各 stage adapter 的 headless_stage 声明、跳过项 → UI/响应: advisory 输出，永不 fail doctor（AC-019）
- **P-015 --pipeline**: Handler/组件: start.sh 参数解析 → 状态: manifest.pipeline 覆盖 conf → API: none/lean=intent/full=intent,spec,plan/逗号列表；未知 stage → exit 1 → 后端: 校验合法值集合 → UI/响应: 错误带合法值列表（AC-020）
- **P-016 失败收割**: Handler/组件: stage.sh 会话等待+收割 → 状态: S3（reason_code=stage_failed、manifest 记退出码/无产物）、锁释放 → API: stage 命令本身 exit 0（收割成功）→ 后端: 会话 stdout 落 `sessions/`；无硬超时（外层可包 timeout）→ UI/响应: 人诊断后重试 stage；TUI needs-human（AC-007）
- **P-017 携带进 repo**: Handler/组件: arena_implementation_bootstrap 的 seed 步骤 → 状态: worktree 内 unstaged `docs/arena/<run-id>/` → API: 无（writer 首 checkpoint 自然包含）→ 后端: copy accepted artifacts；目标存在则跳过（幂等）→ UI/响应: reviewer snapshot=worktree 打包，plan.md 天然在内（AC-009/010）
- **P-018 JSON 兼容**: Handler/组件: `lib/json.sh` 复用 + list.sh row_json → 状态: v0.6-shaped 无 pipeline 键 → API: schema 仍 1、exit==human exit → 后端: Rust `deny_unknown_fields`+`default` → UI/响应: TUI 解析两种形态均通过（AC-012）

## 4. 本轮新发现

| ID | 严重度 | 发现 | 处置 |
|---|---|---|---|
| F9 | Minor | escalate v1 reason-code（reviewer_unreachable）与 stage 卡死场景不匹配，硬扩语义超 v0.7 范围 | 文档化：stage 卡死 → cancel 或 kill+锁回收（F4）；escalate 不动。AC-021 走查版本对应弱化 |
| F10 | Minor | 人工编辑 draft 与 agent 产出在 manifest 不可区分（无 authorship） | 接受：digest 链可回放比对；authorship 字段记 backlog |
| F11 | Minor | 无硬超时——agent 挂起时锁被活 owner 持有，cancel 会被 AC-006 拒绝 | cancel 增特权：允许 kill 持锁 stage 会话 PID 后回收（cancel 本来就是破坏性人类操作） |

## 5. Exit 自查

- [x] 18 条 P-ID 全部闭合（escalate 路径以文档化闭合，见 §0/F9）
- [x] F1（Severe）已决议：`stage --prompt-text/--prompt-file`
- [x] 契约失配/缺接口/状态断续/未定义 UI 响应：无新增 Severe/Major
- [x] 只记录对 Round 1 的增量；目录（§1/§2）被路径引用而非复制
