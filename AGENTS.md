# 项目工作约定

- 项目架构以 `.arch/` 为核心，先用 `arch-grower` CLI `focus` 查看当前节点，再按节点与契约开展工作；`export-ui --out .arch/dashboard.html` 刷新看板。不要直接读写 `.arch/graph.json` 绕过技能的局部视图与更新机制。
- `.arch/ground_truth.md` 保存已确认约束、当前实现和未解问题；更新对应条目，替换已过时的状态。`.arch/graveyard.md` 只保留有用的废弃决策，影子快照通过 CLI 维护。
- 常规文档仅维护根 `README.md`、`README.zh-CN.md`、标准开源社区文件（`CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`、`.github/` Issue/PR 模板）以及 `docs/runbook.md`、`docs/protocol.md`、`docs/record-sync-contract.md`。API 技能和 DSH 插件保留自身必需的分发说明。不要再新增逐轮实施报告、诊断报告、开发日志、清理报告或重复架构图；调试结论归架构事实，必要指标留匿名JSON。
- 稳定结论归入架构事实／既有合同；必要的可复现数据放已忽略的 `analysis/`，阶段性排错代码结束后清理。原始逆向证据、模型、用户录音和签名资料分别保留，不把临时日志当作当前架构事实。
- Python 使用 `uv run python`，不用系统 Python / pip 安装依赖。删除使用 `trash` 或平台回收站 API，不用 `rm`；同盘移动到回收站的大小与磁盘实际释放量分开记录。
- 除非用户明确要求 CI 自动化测试，不新增常驻程序测试或 CI。出现问题后可编写定向临时复现，阶段结束移出测试代码；运行与改动有关的现有检查。
- 开发阶段直接暴露问题，避免非必要校验、过多 try/catch 和 hash 校验。保留用户已有未提交工作，Git 历史重写需要明确授权。
- 主Git跟踪 `.arch` 的六个核心文件（SEED、graph、ground_truth、graveyard、grounding、dashboard），作为普通文件提交；`.arch/.git`仅作本机影子快照，保留并忽略，不添加为submodule。构建／分析数据、下载模型、签名资料和环境缓存不纳入基线。
- 克隆已有项目后直接 `focus`，不要再次 `init` 重建已有图。影子库在后续 `commit-node` 时本地初始化；新克隆的旧影子标签没有对应历史，历史基线通过主Git回溯。
- computer use / browser use 一律委派子代理。用户要求许愿式编程时，交付前由独立代理 code review，修复发现的问题。
- 回答优先结论与证据；确需使用“不代表／不说明”类边界表述前，先给最可能的两种解释，并说明该边界的具体原因。
