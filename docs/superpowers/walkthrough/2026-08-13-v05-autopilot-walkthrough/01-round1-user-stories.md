# v0.5 走查 Round 1 — 用户故事与验收标准（多专家聚合）

> 各专家完整论证见 expert-*.md 的 R1 节。级别：【严重】=阻塞 spec；【主要】=必须进 AC；【次要/信息】=文档化。

## 核心故事（产品视角）

- 有人值守：operator 白天 watch，human 模式审批、提醒、报警并行可用。
- 无人值守：下班前把 run 切 auto，APPROVE+PASS 路径自动完成；异常路径报警。
- 接管：重要 run 收回人工把关；mode 运行期可切（B5 裁定：显式 `mode RUN_ID` 命令）。

## 关键发现

| # | 级别 | 发现 | 来源 | 裁定 |
|---|---|---|---|---|
| B1 | 严重 | actor=autopilot 与 v0.4 枚举冲突（审计撒谎或写坏状态） | security S2 / qa QA-01 | actor=system + action=resolve-approve + reason 实例标识（零契约变更） |
| B5 | 严重 | 无运行期 mode 切换路径，双模式核心工作流不可达 | product R1-1 | 新增 `mode RUN_ID human|auto` + 漂移标记 ⚠ |
| B7 | 严重 | 完成边界未定义（completed ≠ 交付） | sre R1-1 | AC 声明完成边界 + README 非承诺表 |
| B3 | 严重 | pane 活性缺失：submitted/validated + reviewer pane dead 静默停摆 | sre R1-2 / qa QA-02 | state×pane 二维扫描 + 停滞报警 |
| — | 主要 | 承诺过度："无人值守推进到完成"→ 收敛为"自动完成 approval + stop-and-alarm" | statemachine R1-1 / qa QA-05 / product R1-2 | AC 两段式契约 |
| — | 主要 | human 模式"只观测"过弱：提醒/报警应与审批模式解耦 | product R1-3 | human 模式也报警（exit 6） |
| — | 主要 | run 级 opt-in：防 project.conf 单键被静默 uncomment | security S1 | `start --mode auto` 或 init TTY 确认 |
| — | 主要 | mode 漂移无检测：manifest ≠ config 需显示 ⚠ | security M1 | status/list 漂移标记 |
| — | 主要 | auto approve 无冷却窗口、不复核 checkpoint 新鲜度 | security M2 | --approve-delay 默认 5min |
| — | 主要 | 动作矩阵非穷尽、AC2 幂等语义不清（良性竞态 vs 错误） | statemachine R1-2/R1-3 | 全量真值表 + 结果四分类 |
| — | 次要 | 配置 UX：严格 parser + 非法值尽早报错 | product R1-4 | init 模板 + 加载即校验 |
| — | 信息 | AC 编号撞号 v0.4 | qa QA-04 | v05-ACn 命名空间 |

## 修订后 AC 草案（v05-）

- v05-AC1 mode 配置解析 + manifest 落档 + `mode` 切换命令 + status Mode 行 + 漂移标记
- v05-AC2 autopilot `--once`：auto 模式自动 approve（actor=system、reason 实例标识、--approve-delay）
- v05-AC3 auto 模式 APPROVE+PASS 路径端到端闭环 + 幂等（良性竞态只记日志）
- v05-AC4 blocked/停滞/pane-dead 报警（exit 6）+ 永不自动 cancel/reject
- v05-AC5 心跳 autopilot.tsv（每实例一行）+ autopilot.log（result 分类）
- v05-AC6 autopilot 单实例锁（Task 0 修复后）+ 双实例 fixture
- v05-AC7 扫描走 status oracle，exit 4=defer
- v05-AC8 mode 入 creation intent 绑定（中断重试 fail-closed）
- v05-AC9 relay 节流（last_relay_at，默认 30min 冷却）
- v05-AC10 human 模式零动作 + 可报警
- v05-AC11 v0.4 50 节零语义漂移 + N 处显式断言更新清单 + 新增 §50-53
