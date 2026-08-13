# Round 2 — 技术追踪（契约与状态）

每条用户路径按 `用户操作 → Handler → 状态变更 → CLI/API 契约 → 后端逻辑 → 响应 → UI/显示` 追踪。状态根在 `~/.local/state/agent-arena/`，worktree 根在 `~/.local/share/agent-arena/worktrees/`。

## 2.1 Run 状态机

```text
start(新建) ──► RUNNING ──► (writer 提交) ──► submit ──► SUBMITTED ──► validate ──► VALIDATED
   ▲              │                                                              │
   │              └──── resume(start 已有) ◄─────────────────────────────────────┤
   │                                                                            ▼
   │                                                              decision ──► DECIDED
   │                                                                            │
   └────────────── writer 新 checkpoint ──► submit（下一轮）◄────────────────────┘
```

- 无持久化状态字段：状态由**文件存在性**推导（`review.tsv` = SUBMITTED，`validation-<sha>.md` = VALIDATED，`decision-<sha>.md` = DECIDED）。
- **约束**：decision 要求 writer HEAD == review HEAD；validate 要求快照不可变；submit 要求 writer 干净且 HEAD 是 base 的后代。
- **已发现缺陷**：指针文件 `validation.md` / `decision.md` 在 submit 新 checkpoint 后不失效（F2）；状态推导与展示状态可脱节。

## 2.2 文件与状态契约

| 路径 | 写入方 | 权限 | 内容 | 原子性 |
|------|--------|------|------|--------|
| `<run_dir>/manifest.tsv` | start | 600 | 13 字段 TSV：run_id/repository/base_sha/writer_worktree/branch/session_name/tool_root/worktree_root/project_config/profile/writer_adapter/writer_label/writer_session_dir | mktemp+mv ✅ |
| `<run_dir>/review.tsv` | submit | 600 | review_head/review_worktree/cursor_policy_hash/gate_wrapper_hash（64 位 hex 校验） | mktemp+mv ✅ |
| `<run_dir>/validation-<short12>.md` | validate | 600 | 报告含 `Review HEAD: <full>` 与 `RESULT: PASS/FAIL` | mktemp+mv ✅（重跑覆盖，F7） |
| `<run_dir>/validation.md` | validate | 600 | 指针：`Latest validation report: <basename>` | 同上 |
| `<run_dir>/decision-<short12>.md` | decision | 600 | 决策归档（含 verdict/summary/findings/next step） | mktemp+mv ✅ |
| `<run_dir>/decision.md` | decision | 600 | `cp` 归档的指针 | 非原子 ⚠️（cp 非 mktemp） |
| `<run_dir>/writer-session/` | 适配器 | 700 | 通用 writer 私有会话目录（legacy: `pi-session`） | — |
| `worktrees/<repo_id>/<run_id>/writer` | start | — | writer worktree，分支 `agent-arena/<adapter>/<run_id>` | `git worktree add -b` |
| `.../review-<short12>` | submit | — | detached 快照 @ writer HEAD + 生成文件 | `git worktree add --detach` |

**读校验链**：decision 验证报告必须含 `Review HEAD: <full-sha>` 且 `RESULT: PASS`（APPROVE 时）→ 报告由 validate 生成 → validate 前置/后置快照完整性检查 → 完整性绑定 review.tsv 的哈希与 HEAD。审计链闭合。

## 2.3 命令追踪

### doctor

| 环节 | 内容 |
|------|------|
| 操作 | `agent-arena doctor` |
| Handler | lib/doctor.sh → common.sh |
| 契约 | 无参数；probe git/tmux/tmuxp/cursor + 4 个 writer 适配器 |
| 逻辑 | `probe_command`（只查 PATH/ARENA_*_BIN）；cursor 缺失即 failed；每个 profile 依赖适配器 probe |
| 响应 | 表格输出；任一必需缺失 → `arena_die` exit 1 |
| 边界 | 只探测二进制存在，不探测认证/权限（与 AC10 一致）；无副作用 ✅ |

### init

| 环节 | 内容 |
|------|------|
| 操作 | `agent-arena init --repo <path>` |
| Handler | lib/init.sh |
| 契约 | `--repo` 必须为 git 根；写入 `<repo>/.agent-arena/{project.conf,validate.sh}` |
| 逻辑 | 拒绝覆盖（`-e || -L` 检查）；config 用 `project_name` + `validation_script` 键；stub 退出码 2 |
| 响应 | 提示编辑 validate.sh 并提交 |
| 边界 | 不要求干净树、不自动 commit ✅；config 解析严格（未知行 die）✅ |

### start（新建）

| 环节 | 内容 |
|------|------|
| 操作 | `agent-arena start RUN_ID --repo PATH --profile NAME [--state-root --worktree-root --no-attach --log-panes]` |
| Handler | lib/start.sh → profile.sh/common.sh/config.sh |
| 契约 | run_id 正则 + `git check-ref-format`；tmuxp 模板 `templates/tmuxp/arena.yaml` |
| 逻辑 | ① probe 选中 writer + Cursor（先于一切状态）→ ② 集成树干净 + 有 HEAD → ③ 分支不存在、writer 路径不存在 → ④ 建 run_dir/writer-session/worktree（`worktree add -b`）→ ⑤ `arena_write_manifest` → ⑥ 导出 22 个 `ARENA_*` 环境变量 → ⑦ tmuxp load（before_script=preflight.sh） |
| 响应 | run 就绪提示；attach 或 `--no-attach` |
| 边界 | 所有 tmuxp 绑定路径拒绝 `"` `\` 与控制字符；umask 077；run_dir 已存在 → 走恢复路径且 profile 必须一致 |
| 显示 | control pane 打印仓库/run/writer 信息 |

### start（恢复）/ resume

| 环节 | 内容 |
|------|------|
| 操作 | `agent-arena start RUN_ID`（已有 manifest）/ `agent-arena resume RUN_ID` |
| Handler | start.sh（`--run-id` 路径） |
| 逻辑 | 读 manifest → 校验 run_id/repository 一致 → profile 显式传入时须匹配 → writer worktree 存在且分支正确 → 若 review.tsv 存在则声明 review worktree → 二次 probe → 会话存在则刷新 env + attach；否则 tmuxp load |
| 边界 | 恢复不改变 profile（AC9）；preflight 会校验快照完整性 → 快照丢失时会话无法启动（F3） |

### submit

| 环节 | 内容 |
|------|------|
| 操作 | writer（或人）在任意位置 `agent-arena submit RUN_ID` |
| Handler | lib/submit.sh → common.sh |
| 逻辑 | ① 找 run_dir（继承 env 或按 repo 搜索）→ ② writer worktree 干净 → ③ 拒绝跟踪 `.cursor/cli.json` / `.agent-arena-gate` 的 checkpoint → ④ HEAD ≠ base 且为 base 后代 → ⑤ 快照路径 `review-<short12>`：已存在则校验复用，否则 `worktree add --detach` + `arena_prepare_cursor_gate_policy`（policy 600 / wrapper 700，双哈希）→ ⑥ 写 review.tsv → ⑦ 会话运行时刷新 env + `tmux respawn-pane` reviewer |
| 响应 | 提交 SHA + 快照路径 + 提示 Cursor 跑验证 |
| **缺陷** | ⑦ 的 pane 查找失败是**致命**的（`set -e` 下 `arena_find_live_pane` die），但 ①–⑥ 的状态已提交 → 命令失败但状态已变（F1，实锤）；review worktree 被删后 `git worktree add` 报 raw git 错误且无自愈（F3，实锤） |
| 门策略 | allowlist：Read/只读 Shell（git status/diff/show/log、rg/find/ls/cat/sed）+ `./.agent-arena-gate {status,validate,decision,relay}`；deny：Write/Delete/git add/commit/merge/push/reset/checkout/clean/rm（F8：sed 未收窄） |

### validate

| 环节 | 内容 |
|------|------|
| 操作 | Cursor 经 wrapper 或人在 validation pane `agent-arena validate RUN_ID` |
| Handler | lib/validate.sh → common.sh/config.sh |
| 逻辑 | ① review.tsv 存在 → ② 快照 HEAD 一致 + 完整性检查（HEAD/status/哈希/权限/符号链接）→ ③ 读快照内 `.agent-arena/project.conf`（相对路径、禁 `../`）→ ④ `(cd 快照 && .agent-arena/validate.sh)` → ⑤ **后置**完整性检查 → ⑥ 写报告 + 指针 |
| 响应 | 完整报告输出；exit = 门状态（0=通过；2=完整性失败） |
| 边界 | 报告即使失败也写入（RESULT: FAIL）；APPROVE 依赖 PASS 行；重跑覆盖旧报告（F7） |
| 信任模型 | 校验脚本来自快照本身（项目所有）——SHA 绑定使其可审计；完整性后置检查闭环防 `sed -i` 类篡改 |

### decision

| 环节 | 内容 |
|------|------|
| 操作 | Cursor 经 wrapper `./.agent-arena-gate decision RUN_ID --verdict V --summary S --next N [--finding F...] [--no-relay]` |
| Handler | lib/decision.sh → relay.sh |
| 逻辑 | ① 校验 verdict ∈ {APPROVE, CHANGES_REQUESTED, BLOCKED}、文本长度/控制字符 → ② 快照完整 + writer worktree 干净 → ③ **writer HEAD == review HEAD**（越位则拒绝）→ ④ 报告存在且 `Review HEAD` 行绑定 + APPROVE 需 PASS → ⑤ 决策归档不重复 → ⑥ 写归档 + 指针 → ⑦ relay 到 writer（失败仅 note，**exit 0** ✅） |
| 响应 | 记录 verdict + 提示决策文件路径 |
| 边界 | F10：writer 已提交新 checkpoint 后无法对旧 checkpoint 记录决策；F5：不校验调用者身份 |
| 原子性 | 归档 mktemp+mv ✅；`decision.md` 指针用 `cp` 非原子 ⚠️ |

### relay

| 环节 | 内容 |
|------|------|
| 操作 | `agent-arena relay RUN_ID --to writer|reviewer --from writer|reviewer|human --message TEXT` |
| Handler | lib/relay.sh |
| 逻辑 | ① 会话存在 → ② `arena_find_live_pane`：唯一、role+mode 精确匹配（writer-agent/reviewer-agent）、非 dead、input 开、非 copy-mode、非 synchronized → ③ `tmux send-keys -l`（字面量）+ Enter |
| 响应 | relayed 提示；失败 die（decision 内部调用时被捕获为 note） |
| 边界 | 消息 ≤1000 字符、无控制字符（强制单行）；`[Label]` 前缀取自 manifest（writer）或固定 Cursor/Human；发送方标签不可伪造来源真实性（标签由 sender 参数决定，仅 UI 提示） |

### status

| 环节 | 内容 |
|------|------|
| 操作 | `agent-arena status RUN_ID` |
| Handler | lib/status.sh |
| 逻辑 | 读 manifest + review.tsv + 指针文件，纯打印 |
| 响应 | run/repository/base/profile/worktree/branch/session + Review HEAD + Validation + Decision |
| **缺陷** | 无完整性校验（F4）；指针陈旧误导（F2）；Decision 只显示文件路径不显示 verdict 内容 |

## 2.4 Pane 生命周期（templates/tmuxp/arena.yaml + lib/pane.sh）

```text
tmuxp load
  → before_script: lib/preflight.sh   （env 完整性 + manifest 一致性 + 快照完整性）
  → 4 panes（layout: tiled, remain-on-exit: on）
      control    → set_pane_mode control-shell   → cd 集成树 + 提示 + launch_shell(zsh)
      writer     → set_pane_mode writer-agent    → 读 manifest 校验 env → exec <adapter>.sh launch
      reviewer   → set_pane_mode reviewer-agent  → 有 review.tsv: CURSOR_PHASE=review（快照完整性检查）
                                                          无: CURSOR_PHASE=intake（writer worktree, --mode plan）
                   → exec cursor.sh launch
      validation → set_pane_mode validation-shell → cd 快照/writer 树 + 提示 + launch_shell
```

- pane 角色/模式经 `tmux set-option -p @agent_arena_role/@agent_arena_mode` 标记，relay/查找用 `tmux list-panes -F` 过滤。
- **状态转换**：reviewer pane 在 submit 时被 `respawn-pane -k` 重启 → 环境已刷新 → 进入 review 阶段。
- **缺陷**：submit 的 respawn 依赖 reviewer pane 处于精确 live 状态（F1）；real-world 中 Cursor CLI 退出（认证失败/会话结束）→ pane dead → 所有后续 submit 失败。

## 2.5 适配器契约（adapters/README.md + 各 provider）

| 适配器 | probe | 关键 launch 参数 | 危险 flag 禁止 | 会话/恢复 |
|--------|-------|------------------|----------------|-----------|
| pi | `command -v pi` | `--session-dir --session-id --name --append-system-prompt` | —（无沙箱 flag） | 显式 session-id；automatic_resume=true |
| codex | `command -v codex` | `-C <wt> --sandbox workspace-write --ask-for-approval on-request --no-alt-screen` | `--search --add-dir` 及绕过类 | 无创建期 session 契约；不承诺恢复 |
| opencode | `command -v opencode` | `<wt> --pure --agent arena_writer --prompt` + OPENCODE_CONFIG_CONTENT 策略 + 禁用项目配置/外部技能 | `--auto` | 同上 |
| gemini | `command -v gemini` | `--extensions none --allowed-mcp-server-names <哨兵> --approval-mode=auto_edit --session-id/--resume --prompt-interactive` | `--worktree --yolo --skip-trust` | marker 仅在首次进程**成功退出**后发布；失败不发布（原子） |
| cursor | `command -v agent` | `--sandbox enabled --workspace <快照|writer树> [--mode plan]` | 门策略 deny 清单 | — |

**契约要点**：适配器只 `exec` provider CLI，绝不创建 worktree/运行验证/管理凭据/merge/push；probe 只查本地存在性。capabilities 输出稳定行式 flag 供元数据与测试断言（AC9/AC10）。

## 2.6 Round 2 结论

契约层整体闭合：写路径全部原子化（除 decision.md 的 cp）、读路径全部带完整性校验（除 status）、所有 tmuxp 绑定值做了引号/控制字符拒绝、profile 封闭映射杜绝任意可执行文件注入。主要缺陷集中在 **submit 的 pane 耦合（F1/F3）与 status 的审计展示（F2/F4）**，以及 **F5 威胁模型**（应显式写入规范）。
