# Agent Arena v0.2 设计走查 — 发现汇总

走查对象：全部 9 个命令（doctor / init / start / resume / submit / validate / decision / relay / status）、4 个 writer 适配器、Cursor 门策略、tmuxp 模板、preflight 与 pane 生命周期。

基线：`tests/run.sh`（25 段）全绿、`tests/tmuxp-smoke.sh` 通过。以下发现均为**在真实环境（非 fake-CLI）下的可复现行为**，复现脚本见各条目。

## 修复状态（2026-08-13）

F1–F4 已在 `fix/submit-status-best-effort` 分支修复并通过 hermetic 测试（tests/run.sh 新增 §26–§29）与真实环境复验：submit 在 reviewer pane 不可用时降级为提示（AC11）、丢失的快照可自愈重建（AC12）、新 checkpoint 提交时指针失效（AC13）、status 完整性校验 fail-closed（AC14）。F5 已写入 spec 威胁模型与 README。F6–F11 保持开放。

## 结论

设计骨架（worktree 隔离、SHA 绑定、fail-closed、hermetic 测试）是**合理且自洽的**，无方向性错误。但存在 **1 个严重缺陷（阻塞 submit 契约）、3 个主要缺陷（审计显示误导、快照丢失后无法自愈、威胁模型未闭合）**，建议在 v0.2 定稿（Gate 4）前修复或显式记录。

## 发现清单

| # | 级别 | 发现 | 证据 | 建议 |
|---|------|------|------|------|
| F1 | **严重** | `submit` 在**快照与 review.tsv 已创建之后**，因 reviewer pane 非 live（死掉/仍在 initializing）而整体 `exit 1`；pane 恢复 live 前重试持续失败，且状态已变更（exit code 说谎）。与 `decision` 的 relay 失败处理（graceful note + exit 0）不对称 | 真实 tmux 会话复现两次；`tmux list-panes` 显示 `reviewer-agent dead=1` | pane 刷新/respawn 改为 best-effort（`if ! ...; then arena_note`），与 decision 的 relay 一致；或把 pane 检查移到状态变更之前 |
| F2 | **主要** | 新 checkpoint 提交后，`status` 的 Validation/Decision 指针仍指向**旧 checkpoint**（`validation.md`/`decision.md` 不被 submit 失效）；审查者/审计者可能误以为新 HEAD 已通过验证 | c1 全流程 APPROVE 后提交 c2 并 submit，`status` 显示 Review HEAD=c2 但 Validation/Decision 仍是 c1 | submit 时删除或标注旧指针文件（归档保留）；或 status 打印指针与当前 Review HEAD 的绑定关系 |
| F3 | **主要** | 审查快照被删除（手工 rm）后，`submit` 与 `start` 均永久失败：git 报 "lost but registered worktree"、preflight 报 "worktree does not exist"；Arena 无任何自愈命令 | `rm -rf review-<sha>` 后 submit/start 复现 | `submit` 先 `git worktree prune`（非破坏性，只清注册）；或给出可执行的恢复提示 |
| F4 | **主要** | `status`（审计者唯一工具）**不做任何完整性校验**：快照被篡改、HEAD 漂移、报告被替换时 status 照常显示；validate/decision 才检查 | 代码审查：status.sh 只读 manifest | status 增加 `arena_review_snapshot_is_intact` 校验（只读、不修），失败时明示 |
| F5 | **主要** | 威胁模型未闭合：writer 与 Cursor **同 UID**，writer 的 prompt/环境直接包含 `ARENA_COMMAND` 与 `ARENA_RUN_DIR`；writer 可自行伪造 validation 报告并执行 `decision` 自批准。"Cursor-only gate" 仅靠 prompt + Cursor 侧 allowlist 约束（只约束 Cursor，不约束 writer） | 代码审查：decision/validate 不校验调用者身份；run_dir 700 但同 UID 可写 | 在 spec/README 威胁模型中显式声明"正式门依赖 writer 遵守 prompt，无法在本地同 UID 下用能力强制"；可选缓解：decision 需人工 TTY 确认 |
| F6 | 次要 | 无 run 列表、无任何非破坏性恢复/清理命令；孤儿 worktree/分支/临时文件只能手工 git 处理 | 代码审查：无 list/prune/clean 命令 | 加 `list`；文档化手工恢复步骤 |
| F7 | 次要 | `validation-<sha>.md` 重跑会被覆盖，FAIL 历史丢失 | 代码审查：validate.sh `mv` 覆盖 | 追加时间戳后缀或保留历史 |
| F8 | 次要 | Cursor allowlist 含 `Shell(sed *)`，`sed -i` 是写向量；理论上可后台竞态篡改校验脚本。post-run 完整性检查使其难以可靠利用，但属于纵深防御缺口 | 代码审查：common.sh 生成的 policy | 收窄为 `Shell(sed -n *)` 或移除 |
| F9 | 信息 | Gemini 首次会话被 SIGKILL 时残留 `.gemini-session-id.*` 临时 marker | 代码审查：gemini.sh 仅在成功退出时清理 | 启动时清理同目录残留临时 marker |
| F10 | 信息 | 决策-提交顺序约束：writer 在评审期间提交新 checkpoint 后，评审者**无法**再对旧 checkpoint 记录 CHANGES_REQUESTED（decision 要求 writer HEAD == review HEAD）。流程正确但容易踩 | 代码审查：decision.sh | 文档化该约束与推荐节奏 |
| F11 | 信息 | `start` 在 tmuxp `before_script` 失败时泄漏 Python traceback（fail-closed 行为正确，UX 差） | 真实复现 | 捕获 tmuxp 输出只展示 preflight 错误 |

## 复现命令（全部在真实 git + tmux 环境）

```bash
# F1/F2/F3 复现环境
ARENA_STATE_ROOT=/tmp/arena-wt/state ARENA_WORKTREE_ROOT=/tmp/arena-wt/worktrees \
  bin/agent-arena start r1 --no-attach   # 真实 tmuxp 起会话
# 提交 checkpoint、submit —— 若 reviewer pane 死亡或未就绪：
bin/agent-arena submit r1                # → exit 1 "reviewer pane is unavailable or ambiguous"
# 但 review.tsv 与 review-<sha> 快照已生成（validate 仍可用）
```

## 走查文档

- [Round 1 — 用户故事与 AC](01-round1-user-stories.md)
- [Round 2 — 技术追踪（契约与状态）](02-round2-technical-trace.md)
- [Round 3 — 集成与错误矩阵](03-round3-integration-check.md)
