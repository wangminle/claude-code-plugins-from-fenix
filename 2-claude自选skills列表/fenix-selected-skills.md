# 自选 Claude Skills 名单

> 本文件由名单脚本（`fenix-selected-skills.sh` / `fenix-selected-skills.ps1`）从 [fenix-selected-skills.json](fenix-selected-skills.json) 自动生成，请勿手改。
> 安装只拉取 skills[].path 指向的子目录（git blobless + sparse checkout），不会下载整个仓库。
> path 为空或为 "." 表示技能位于仓库根目录；此时无法只取子目录，安装会整仓浅克隆，脚本会提示。
> check --network 只读取每个 skill 的 SKILL.md 做校验，不下载仓库。
> sync 先检查目标目录：缺失则安装最新版；已存在则核对目录名、SKILL.md 的 name 与版本，过旧则更新；非本工具安装的目录会先备份到 <目标目录>/.backups/。
> 默认安装到用户级 ~/.claude/skills；--target project 安装到当前目录的 .claude/skills，--target <目录> 可指定任意位置。
> 平台：macOS / Linux / WSL 使用 fenix-selected-skills.sh；Windows 使用 fenix-selected-skills.ps1 或 fenix-selected-skills.cmd；脚本会自动检测环境并切换对应实现。

共 45 项 · 更新于 2026-11-24 13:30

| 类型 | 名称 | GitHub | 仓库路径 | 最新版本 | 说明 |
| --- | --- | --- | --- | --- | --- |
| 文档处理 | docx | [anthropics/skills](https://github.com/anthropics/skills) | skills/docx | e4bb5d96 | 创建、读取、编辑 Word 文档（含修订与批注） |
| 文档处理 | docx-to-markdown | [wangminle/skills-doc-to-md](https://github.com/wangminle/skills-doc-to-md) | skills/docx-to-markdown | d2415eb1 | Word 转 Markdown（含嵌入 Excel 表格与图片提取） |
| 文档处理 | pdf | [anthropics/skills](https://github.com/anthropics/skills) | skills/pdf | e4bb5d96 | PDF 读取、合并拆分、表单与水印 |
| 文档处理 | pdf-markdown-summary | [wangminle/skills-pdf-markdown-summary](https://github.com/wangminle/skills-pdf-markdown-summary) | skills/pdf-markdown-summary | 4922d0ee | PDF 转 Markdown 并提取图表做阅读摘要 |
| 文档处理 | pptx | [anthropics/skills](https://github.com/anthropics/skills) | skills/pptx | e4bb5d96 | 生成与编辑 PowerPoint 演示文稿 |
| 文档处理 | scanned-pdf-editor | [wangminle/skills-scanned-pdf-editor](https://github.com/wangminle/skills-scanned-pdf-editor) | skills/scanned-pdf-editor | fa4c1ef1 | 扫描版 PDF 或图片的局部编辑 |
| 文档处理 | xlsx | [anthropics/skills](https://github.com/anthropics/skills) | skills/xlsx | e4bb5d96 | 读写 Excel 表格、公式与图表 |
| 内容抓取 | webpage-to-md | [wangminle/skills-webpage-to-md](https://github.com/wangminle/skills-webpage-to-md) | skills/webpage-to-md | 8e4d8dda | 网页文章保存为 Markdown 并下载图片到本地 |
| 内容创作 | algorithmic-art | [anthropics/skills](https://github.com/anthropics/skills) | skills/algorithmic-art | e4bb5d96 | 用 p5.js 生成算法艺术 |
| 内容创作 | brand-guidelines | [anthropics/skills](https://github.com/anthropics/skills) | skills/brand-guidelines | e4bb5d96 | 应用 Anthropic 品牌色与版式 |
| 内容创作 | canvas-design | [anthropics/skills](https://github.com/anthropics/skills) | skills/canvas-design | e4bb5d96 | 生成海报、插画等静态视觉作品 |
| 内容创作 | doc-coauthoring | [anthropics/skills](https://github.com/anthropics/skills) | skills/doc-coauthoring | e4bb5d96 | 结构化文档协作写作流程 |
| 内容创作 | internal-comms | [anthropics/skills](https://github.com/anthropics/skills) | skills/internal-comms | e4bb5d96 | 内部沟通文稿（状态报告、通报、FAQ 等） |
| 内容创作 | slack-gif-creator | [anthropics/skills](https://github.com/anthropics/skills) | skills/slack-gif-creator | e4bb5d96 | 制作适配 Slack 的动画 GIF |
| 内容创作 | theme-factory | [anthropics/skills](https://github.com/anthropics/skills) | skills/theme-factory | e4bb5d96 | 为幻灯片、网页、报告套用主题 |
| 内容创作 | writing-guidelines | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | skills/writing-guidelines | 5a37a632 | UI 文案与界面写作规范 |
| 前端开发 | composition-patterns | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | skills/composition-patterns | 5a37a632 | React 组合式组件设计模式 |
| 前端开发 | deploy-to-vercel | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | skills/deploy-to-vercel | 5a37a632 | 把项目部署到 Vercel |
| 前端开发 | frontend-design | [anthropics/skills](https://github.com/anthropics/skills) | skills/frontend-design | e4bb5d96 | 高质量前端界面与视觉设计 |
| 前端开发 | impeccable | [pbakaus/impeccable](https://github.com/pbakaus/impeccable) | .claude/skills/impeccable | skill-v4.10.0 | 设计、重构、审查、打磨前端界面与设计系统 |
| 前端开发 | react-best-practices | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | skills/react-best-practices | 5a37a632 | React / Next.js 性能最佳实践 |
| 前端开发 | react-native-skills | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | skills/react-native-skills | 5a37a632 | React Native / Expo 开发实践 |
| 前端开发 | react-view-transitions | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | skills/react-view-transitions | 5a37a632 | React 视图过渡动画 |
| 前端开发 | web-artifacts-builder | [anthropics/skills](https://github.com/anthropics/skills) | skills/web-artifacts-builder | e4bb5d96 | 构建多组件 Web Artifact |
| 前端开发 | web-design-guidelines | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | skills/web-design-guidelines | 5a37a632 | Web 界面与可访问性规范审查 |
| 前端开发 | webapp-testing | [anthropics/skills](https://github.com/anthropics/skills) | skills/webapp-testing | e4bb5d96 | 用 Playwright 测试本地 Web 应用 |
| 开发流程 | brainstorming | [obra/superpowers](https://github.com/obra/superpowers) | skills/brainstorming | v7.0.2 | 动工前澄清需求与设计 |
| 开发流程 | dispatching-parallel-agents | [obra/superpowers](https://github.com/obra/superpowers) | skills/dispatching-parallel-agents | v7.0.2 | 并行派发互不依赖的任务 |
| 开发流程 | executing-plans | [obra/superpowers](https://github.com/obra/superpowers) | skills/executing-plans | v7.0.2 | 按计划执行并在检查点复核 |
| 开发流程 | finishing-a-development-branch | [obra/superpowers](https://github.com/obra/superpowers) | skills/finishing-a-development-branch | v7.0.2 | 分支收尾：合并、PR 或清理 |
| 开发流程 | receiving-code-review | [obra/superpowers](https://github.com/obra/superpowers) | skills/receiving-code-review | v7.0.2 | 严谨处理审查意见而非盲从 |
| 开发流程 | requesting-code-review | [obra/superpowers](https://github.com/obra/superpowers) | skills/requesting-code-review | v7.0.2 | 完成后发起代码审查 |
| 开发流程 | subagent-driven-development | [obra/superpowers](https://github.com/obra/superpowers) | skills/subagent-driven-development | v7.0.2 | 用子代理执行独立任务 |
| 开发流程 | systematic-debugging | [obra/superpowers](https://github.com/obra/superpowers) | skills/systematic-debugging | v7.0.2 | 系统化定位 bug 根因 |
| 开发流程 | test-driven-development | [obra/superpowers](https://github.com/obra/superpowers) | skills/test-driven-development | v7.0.2 | 先写失败测试再实现 |
| 开发流程 | using-git-worktrees | [obra/superpowers](https://github.com/obra/superpowers) | skills/using-git-worktrees | v7.0.2 | 用 git worktree 隔离开发 |
| 开发流程 | verification-before-completion | [obra/superpowers](https://github.com/obra/superpowers) | skills/verification-before-completion | v7.0.2 | 声称完成前先跑验证拿证据 |
| 开发流程 | writing-plans | [obra/superpowers](https://github.com/obra/superpowers) | skills/writing-plans | v7.0.2 | 编写分步实施计划 |
| 开发流程 | writing-skills | [obra/superpowers](https://github.com/obra/superpowers) | skills/writing-skills | v7.0.2 | 编写与调试 Skill |
| 工程工具 | claude-api | [anthropics/skills](https://github.com/anthropics/skills) | skills/claude-api | e4bb5d96 | Claude API 参考（模型、价格、流式、工具调用） |
| 工程工具 | mcp-builder | [anthropics/skills](https://github.com/anthropics/skills) | skills/mcp-builder | e4bb5d96 | 构建高质量 MCP 服务器 |
| 工程工具 | skill-creator | [anthropics/skills](https://github.com/anthropics/skills) | skills/skill-creator | e4bb5d96 | 创建、改进与评测 Skill |
| 项目管理 | task-list-initialization | [wangminle/skills-task-list-initialization](https://github.com/wangminle/skills-task-list-initialization) | skills/task-list-initialization | 37ca88ab | 建立与检查项目任务台账 task-list.md |
| 辅助增强 | academy-guide | [anthropics/skills](https://github.com/anthropics/skills) | skills/academy-guide | e4bb5d96 | 回答问题前推荐 Claude Academy 的课程、教程与用例 |
| 辅助增强 | discernment-nudge | [anthropics/skills](https://github.com/anthropics/skills) | skills/discernment-nudge | e4bb5d96 | 实质性回答后追加 2~3 个追问，帮用户核对事实、推理与遗漏背景 |

同步：`fenix-selected-skills.sh sync`（Windows：`fenix-selected-skills.ps1 sync`） · 查状态：`fenix-selected-skills.sh status` · 帮助：`fenix-selected-skills.sh help`
