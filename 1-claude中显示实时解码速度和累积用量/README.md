# Claude Code 状态栏：解码速度与累积用量

`statusline-tokens.py` 在 Claude Code 终端状态栏显示本轮解码速度、会话平均速度、会话输出量、今日与自重置用量、上下文占用和当前模型。脚本只使用 Python 标准库，支持 macOS、Linux 和 Windows，需要 Python 3.7+。

示例：

```text
⏱ 本轮 42.7 tok/s · 平均 38.1 tok/s · 1.2M out · 今日 117.4M tok · 自重置 6.4M tok · ctx 23% · Opus 5
```

## 安装

在 `~/.claude/settings.json` 中加入 `statusLine`，并把路径换成本脚本的实际绝对路径。

macOS / Linux：

```json
"statusLine": {
  "type": "command",
  "command": "python3 '/绝对/路径/statusline-tokens.py'"
}
```

Windows `cmd.exe` 使用双引号和 `python`；JSON 中的反斜杠必须双写：

```json
"statusLine": {
  "type": "command",
  "command": "python \"C:\\绝对\\路径\\statusline-tokens.py\""
}
```

路径含空格或中文时必须按所用 shell 正确加引号。改完后开新会话生效。该配置只对终端中的 `claude` CLI 生效，Claude Desktop 不读取它。

默认只在事件发生时刷新。若希望每秒重算，可在 `statusLine` 中加入 `"refreshInterval": 1`，代价是每秒多启动一个 Python 进程。

## 指标口径

- **本轮**：本次真实提问后新增的 output tokens 除以本轮 API 耗时；不足 0.8 秒不显示。只认 `promptSource` 为 `typed`、`sdk`、`queued` 的提问，系统通知和工具结果不另起一轮。
- **平均**：本会话累计 output tokens 除以累计 API 耗时，包含工具往返等空转；恢复会话时按当前 Claude Code 进程重新建立基线，避免历史输出除以新进程耗时。
- **N out**：当前 transcript 中按 `message.id` 去重后的 output tokens。transcript 不可读时，回退到 `context_window.total_output_tokens`。
- **今日 / 自重置**：递归读取 `~/.claude/projects` 下所有会话及 `subagents/*.jsonl`，统计 input、output 和缓存读写 token。「自重置」从最近一次 `--reset` 开始，未重置时从首次运行开始。
- **ctx / 模型名**：直接使用 Claude Code 传入的上下文占用和模型显示名。

## 命令行

```bash
python3 statusline-tokens.py           # 从 stdin 读取 Claude Code JSON
python3 statusline-tokens.py --reset   # 把“自重置”起点设为现在
python3 statusline-tokens.py --help
```

未知参数会输出用法并以状态码 2 退出，不会进入 stdin 等待。手动试跑时，先把示例中的 `x/y.jsonl` 换成真实 transcript 文件名：

```bash
echo '{"transcript_path":"~/.claude/projects/x/y.jsonl","cost":{"total_api_duration_ms":5000}}' \
  | python3 statusline-tokens.py
```

## 数据与缓存

默认文件如下；设置 `XDG_CACHE_HOME` 时，用该目录替代 `~/.cache`：

| 文件 | 用途 |
| --- | --- |
| `~/.cache/claude-statusline/usage-index.json` | 今日与自重置统计的跨会话增量索引 |
| `~/.cache/claude-statusline/usage-index.lock` | Unix 索引写锁 |
| `~/.cache/claude-statusline/<hash>.json` | 各 transcript 的读取位置与速度基线 |
| `~/.cache/claude-statusline/last-sweep` | 缓存每日清理的节流标记 |
| `~/.claude/statusline-usage-reset.json` | 最近一次重置时间 |

索引会裁掉两个统计窗口都不再需要的记录；30 天未更新的单会话缓存每天最多清理一次。删除缓存不会删除 transcript，但下次需要全量重扫。缓存、索引和重置文件均采用唯一临时文件加原子替换写入，读写使用 UTF-8。Windows 没有 `fcntl` 时自动退化为不加锁，仍按消息 ID 去重。

## 验证

在仓库根目录运行：

```bash
python3 -m unittest discover -s tests -v
```
