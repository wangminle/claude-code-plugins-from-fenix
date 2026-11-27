#!/usr/bin/env python3
"""Claude Code 状态栏：实时解码速度 + 累积用量。

═══════════════════════════════════════════════════════════════════
一、长什么样
═══════════════════════════════════════════════════════════════════

  ⏱ 本轮 42.7 tok/s · 平均 38.1 tok/s · 1.2M out · 今日 117.4M tok
    · 自重置 6.4M tok · ctx 23% · Opus 5

  ⏱ 本轮  本次提问后新增的 output tokens ÷ 本轮 API 耗时。不足 0.8 秒
          不显示（样本太短、抖动大）。只认你真正发起的提问
          （promptSource 为 typed/sdk/queued），系统通知、工具结果不计入。
  平均     本会话累计 output tokens ÷ 本会话累计 API 耗时；含工具往返
          等空转，通常低于瞬时速度，当下界看即可。
  N out    本会话 transcript 里累计的 output tokens。
  今日     本地 0 点至今、所有会话的 input + output + 缓存读写总量，
          递归统计子代理的 subagents/*.jsonl。
  自重置   同上口径，起点是最近一次 --reset（没重置过则以首次运行时刻为起点）。
  ctx      context 已用百分比，由 Claude Code 直接传入。
  末尾     当前模型显示名。

═══════════════════════════════════════════════════════════════════
二、怎么装上
═══════════════════════════════════════════════════════════════════

需要 Python 3.7+，只用标准库。在 ~/.claude/settings.json 里加（路径换成
本脚本的实际位置；JSON 字符串中的 Windows 反斜杠要写成双反斜杠）：

  macOS / Linux：
  "statusLine": {
    "type": "command",
    "command": "python3 '/绝对/路径/statusline-tokens.py'"
  }

  Windows cmd.exe（双引号；python3 可能命中 Microsoft Store 占位符）：
  "statusLine": {
    "type": "command",
    "command": "python \"C:\\绝对\\路径\\statusline-tokens.py\""
  }

  * 只对终端里的 claude CLI 生效；Claude Desktop 的界面不读这个配置。
  * 路径含空格或中文时必须按所用 shell 正确加引号。
  * 想让它每秒重算（默认只在事件发生时刷新）再加 "refreshInterval": 1，
    代价是每秒多起一个 python 进程。
  * 只用标准库。文件锁依赖 Unix 的 fcntl，Windows 上自动退化为不加锁：
    单机单会话没有区别，多会话并发时最多重复解析同一段 transcript
    （按 message.id 去重，不会重复计数）。
  * 改完开新会话才生效。

═══════════════════════════════════════════════════════════════════
三、命令行
═══════════════════════════════════════════════════════════════════

  python3 statusline-tokens.py --reset     # 把“自重置”起点设为现在
  python3 statusline-tokens.py --no-cache  # 只读试跑，不读写缓存/索引/重置文件
  python3 statusline-tokens.py --help      # 帮助
  python3 statusline-tokens.py             # 正常模式：从 stdin 读 Claude Code 的 JSON

  手动试跑（先把 x/y.jsonl 换成真实 transcript 文件名；--no-cache 避免污染活动会话）：

  echo '{"transcript_path":"~/.claude/projects/x/y.jsonl","cost":{"total_api_duration_ms":5000}}' \\
    | python3 statusline-tokens.py --no-cache

═══════════════════════════════════════════════════════════════════
四、数据文件（都在家目录，脚本不写当前目录）
═══════════════════════════════════════════════════════════════════

  ~/.cache/claude-statusline/usage-index.json   跨会话增量索引（今日/自重置口径）
  ~/.cache/claude-statusline/<hash>.json        单会话缓存（按 transcript 路径哈希）
  ~/.cache/claude-statusline/usage-index.lock   索引写锁
  ~/.cache/claude-statusline/last-sweep         单会话缓存的每日清理节流标记
  ~/.claude/statusline-usage-reset.json         最近一次 --reset 的时间戳

设置 XDG_CACHE_HOME 时，上述 ~/.cache 替换为该目录。transcript 不可读时，
N out 回退到 Claude Code 传入的 context_window.total_output_tokens。
索引只保留「今日」和「自重置」两个窗口仍然需要的记录，更早的每次写回时
自动裁掉，所以不会随历史无限增长。单会话缓存 30 天没更新会自动清理（每天
最多扫一次，只清早就不再使用的会话）。删掉 ~/.cache/claude-statusline 不丢
数据，只是下次要全量重扫 ~/.claude/projects（几百 MB 时首次数秒）。

═══════════════════════════════════════════════════════════════════
五、实现要点
═══════════════════════════════════════════════════════════════════

* Claude Code 通过 stdin 传入一份 JSON（transcript_path、
  cost.total_api_duration_ms、context_window、model 等）。
* transcript 是 JSONL，按字节 offset 增量读取，只解析新增部分；
  末尾写了一半的行留到下次再说。
* 同一条 assistant 消息在流式过程中会被写入多条 usage 快照，必须按
  message.id 去重取最大值，否则会重复计数。
* 「本轮」基线取自最早检测到新 prompt 的那次刷新：api 时长取当时的值，
  输出总量取「该 prompt 在 transcript 里出现时」的累计值，同一块里它
  之后的 assistant 输出属于本轮，不会被吞进基线。
* cost.total_api_duration_ms 在 resume 时可能恢复为全会话累计值，因此「平均」
  始终直接用 total_out/api_ms；只有「本轮」维护基线，累计值异常回退时才重置。
* 所有缓存与索引都原子写（每次写独立临时文件再 os.replace），读写一律
  显式 UTF-8，stdin/stdout 也强制 UTF-8（Windows 默认 gbk/cp1252 不会崩）。
* 外部 JSON（stdin、缓存、索引、transcript 行）一律按「形状不对就丢弃」
  处理，bool 不算数字。
* 统计失败一律吞掉：状态栏宁可少一项指标，也不能因为算不出数字整行空掉。
"""

import datetime
import glob
import hashlib
import json
import math
import os
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:  # Windows 没有 flock：退化为不加锁，统计照常可用
    fcntl = None

CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "claude-statusline",
)
USAGE_INDEX = os.path.join(CACHE_DIR, "usage-index.json")
USAGE_LOCK = os.path.join(CACHE_DIR, "usage-index.lock")
RESET_FILE = os.path.expanduser("~/.claude/statusline-usage-reset.json")
TRANSCRIPT_ROOT = os.path.expanduser("~/.claude/projects")

TURN_MIN_MS = 800  # 本轮过短时速度抖动大，先不显示

# 哪些 promptSource 才算「用户开了一轮」。注意系统注入的消息（后台任务完成
# 通知、跨会话消息、各种提醒）带的是 "system"，它们既不是 isMeta 也不是工具
# 结果；若按旧逻辑当成新提问，本轮速度的基线会在回复中途被重置，显示值突然
# 变成 -- 或一个明显偏小的数。
REAL_PROMPT_SOURCES = ("typed", "sdk", "queued")

# 单会话缓存（<16 位 hash>.json）保留天数：超过这么久没更新就清掉，免得
# 一个会话留一个文件无限堆积。与 Claude Code 默认的 transcript 保留期
# （cleanupPeriodDays=30）对齐；活跃会话每次渲染都会刷新 mtime，删不到。
SESSION_CACHE_TTL_DAYS = 30
SESSION_CACHE_SWEEP_MARK = os.path.join(CACHE_DIR, "last-sweep")


def _is_int(value):
    """真正的整数：bool 是 int 的子类，必须排除（True 不是 1 个 token）。"""
    return isinstance(value, int) and not isinstance(value, bool)


def _is_num(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def _dict(value):
    return value if isinstance(value, dict) else {}


def _atomic_write_json(path, obj, **dump_kwargs):
    """原子写 JSON：每次写独立的临时文件再 os.replace。

    固定的 <path>.tmp 在多进程并发时会被互相截断、互相 replace 走；
    用 mkstemp 的唯一文件名，最坏情况只是后写者覆盖先写者。
    """
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(
        prefix=os.path.basename(path) + ".", suffix=".tmp", dir=directory
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, **dump_kwargs)
        for attempt in range(20):
            try:
                os.replace(tmp, path)
                break
            except PermissionError:
                # Windows 上目标文件被另一个状态栏进程短暂打开时可能拒绝替换。
                if attempt == 19:
                    raise
                time.sleep(0.005 * (attempt + 1))
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def _force_utf8_stdio():
    """Windows 中文版默认 gbk/cp1252：不重配的话输出 ⏱ 会 UnicodeEncodeError。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError, OSError):
            pass


def _read_stdin_json():
    try:
        raw = getattr(sys.stdin, "buffer", None)
        if raw is not None:
            text = raw.read().decode("utf-8", errors="replace")
        else:
            text = sys.stdin.read()
        return json.loads(text)
    except (ValueError, OSError):
        return None


def load_cache(path):
    """读单会话缓存；任何形状不对的字段都丢弃，绝不抛异常。"""
    blank = {"offset": 0, "msgs": {}}
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return blank
    if not isinstance(d, dict):
        return blank
    offset = d.get("offset")
    msgs = d.get("msgs")
    if not _is_int(offset) or offset < 0 or not isinstance(msgs, dict):
        return blank
    state = {
        "offset": offset,
        "msgs": {
            k: v
            for k, v in msgs.items()
            if isinstance(k, str) and _is_int(v) and v >= 0
        },
    }
    if isinstance(d.get("prompt"), str):
        state["prompt"] = d["prompt"]
    if (
        _is_num(d.get("base_api_ms"))
        and d["base_api_ms"] >= 0
        and _is_int(d.get("base_out"))
        and d["base_out"] >= 0
    ):
        state["base_api_ms"] = d["base_api_ms"]
        state["base_out"] = d["base_out"]
    if _is_num(d.get("last_api_ms")) and d["last_api_ms"] >= 0:
        state["last_api_ms"] = d["last_api_ms"]
    return state


def save_cache(path, state):
    _atomic_write_json(path, state, separators=(",", ":"))


def scan_new(path, offset, msgs):
    """从 offset 起读取完整行。

    返回 (新 offset, 本块中最后一条用户 prompt 的 id, 该 prompt 出现时 msgs
    的 output 累计值)。第三项是「本轮」基线：同一块里 prompt 之后才出现的
    assistant 输出属于本轮，不能被算进基线。

    用户 prompt 用 promptId 识别（本地命令输出、工具结果都没有该字段）。
    """
    with open(path, "rb") as f:
        f.seek(offset)
        buf = f.read()
    if not buf:
        return offset, None, None
    last_nl = buf.rfind(b"\n")
    if last_nl < 0:
        return offset, None, None  # 最后一行还没写完，下次再解析
    last_prompt = None
    base_at_prompt = None
    running = sum(msgs.values())
    for line in buf[: last_nl + 1].splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        typ = obj.get("type")
        if typ == "user":
            # 白名单而非「有 promptSource 就算」：工具结果条目不只有 promptId，
            # 系统注入的通知还带 promptSource="system"（本地 transcript 里
            # 有数百条），把它们算成新提问会让本轮速度的基线中途归零。
            if obj.get("promptSource") not in REAL_PROMPT_SOURCES:
                continue
            if obj.get("isMeta"):
                continue
            content = _dict(obj.get("message")).get("content")
            if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result"
                for b in content
            ):
                continue
            pid = obj.get("promptId")
            if pid and isinstance(pid, str):
                last_prompt = pid
                base_at_prompt = running
            continue
        if typ != "assistant" or b'"output_tokens"' not in line:
            continue
        msg = _dict(obj.get("message"))
        n = _dict(msg.get("usage")).get("output_tokens")
        mid = msg.get("id")
        if not _is_int(n) or n <= 0 or not isinstance(mid, str) or not mid:
            continue
        old = msgs.get(mid, 0)
        if n > old:
            msgs[mid] = n
            running += n - old
    return offset + last_nl + 1, last_prompt, base_at_prompt


def _int(value):
    return value if _is_int(value) and value > 0 else 0


def parse_ts(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.fromisoformat(
            value.replace("Z", "+00:00")
        ).timestamp()
    except (ValueError, OSError, OverflowError):
        return None


def read_reset_ts():
    try:
        with open(RESET_FILE, encoding="utf-8") as f:
            data = json.load(f)
        ts = _dict(data).get("reset_ts")
        if _is_num(ts) and ts > 0:
            return float(ts)
    except (OSError, ValueError, TypeError):
        pass
    return None


def write_reset_ts(ts):
    _atomic_write_json(
        RESET_FILE,
        {
            "reset_ts": ts,
            "reset_at": datetime.datetime.fromtimestamp(
                ts, tz=datetime.timezone.utc
            ).astimezone().isoformat(),
        },
    )


def load_usage_index():
    try:
        with open(USAGE_INDEX, encoding="utf-8") as f:
            data = json.load(f)
        if (
            isinstance(data, dict)
            and data.get("v") == 1
            and isinstance(data.get("files"), dict)
        ):
            return data
    except (OSError, ValueError):
        pass
    return {"v": 1, "files": {}}


def save_usage_index(index):
    # 默认 ensure_ascii：路径里的非 ASCII 字符（甚至无法解码的字节）写成
    # \uXXXX，与系统默认编码无关。
    _atomic_write_json(USAGE_INDEX, index, separators=(",", ":"))


def scan_usage_file(path, entry):
    """增量扫描一个 transcript，返回 (新 offset, 消息表, 是否有变化)。

    消息表按 message.id 去重，保存 [时间戳, 总 token]。同一消息的流式
    快照只保留最大值，避免重复计数。
    """
    entry = _dict(entry)
    offset = entry.get("offset", 0)
    if not _is_int(offset) or offset < 0:
        offset = 0
    msgs = entry.get("msgs")
    if not isinstance(msgs, dict):
        msgs = {}

    try:
        size = os.path.getsize(path)
    except OSError:
        return offset, msgs, False

    truncated = size < offset
    if truncated:
        offset, msgs = 0, {}
    changed = truncated

    try:
        with open(path, "rb") as f:
            f.seek(offset)
            buf = f.read()
    except OSError:
        return offset, msgs, changed
    if not buf:
        return offset, msgs, changed

    last_nl = buf.rfind(b"\n")
    if last_nl < 0:
        return offset, msgs, changed

    for line in buf[: last_nl + 1].splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict) or obj.get("type") != "assistant":
            continue
        msg = _dict(obj.get("message"))
        usage = _dict(msg.get("usage"))
        mid = msg.get("id")
        out = usage.get("output_tokens")
        if not _is_int(out) or out < 0 or not isinstance(mid, str) or not mid:
            continue
        ts = parse_ts(obj.get("timestamp"))
        if ts is None:
            continue
        total = (
            _int(usage.get("input_tokens"))
            + out
            + _int(usage.get("cache_creation_input_tokens"))
            + _int(usage.get("cache_read_input_tokens"))
        )
        if total <= 0:
            continue
        old = msgs.get(mid)
        old_total = (
            old[1]
            if isinstance(old, list)
            and len(old) >= 2
            and _is_int(old[1])
            else 0
        )
        if total > old_total:
            msgs[mid] = [ts, total]
            changed = True

    new_offset = offset + last_nl + 1
    if new_offset != offset:
        changed = True
    return new_offset, msgs, changed


def totals_from_index(index, today_start, reset_ts):
    """把索引里的消息记录按时间窗口汇总成 (今日, 自重置)。"""
    today = 0
    since_reset = 0
    for entry in index["files"].values():
        msgs = _dict(entry).get("msgs")
        if not isinstance(msgs, dict):
            continue
        for rec in msgs.values():
            if not isinstance(rec, list) or len(rec) < 2:
                continue
            ts, total = rec[0], rec[1]
            if not _is_num(ts) or not _is_int(total) or total < 0:
                continue
            if ts >= today_start:
                today += total
            if ts >= reset_ts:
                since_reset += total
    return today, since_reset


def prune_index(index, cutoff):
    """丢掉早于 cutoff 的记录，返回丢掉的条数。

    早于 today_start 与 reset_ts 中较早者的消息，再也进不了任何一个统计
    窗口，留着纯属占地方——而这份索引每次有变化都要整体重写一遍。实测本机
    两万多条记录里有 97% 属于这一类，不裁的话文件只会随使用历史一直变大。
    顺带清掉指向已删除 transcript 的空条目。
    """
    dropped = 0
    for path in list(index["files"]):
        entry = index["files"][path]
        if not isinstance(entry, dict):
            del index["files"][path]
            dropped += 1
            continue
        msgs = entry.get("msgs")
        if not isinstance(msgs, dict):
            msgs = {}
        stale = [
            mid
            for mid, rec in msgs.items()
            if not (
                isinstance(rec, list)
                and len(rec) >= 2
                and _is_num(rec[0])
                and rec[0] >= cutoff
                and _is_int(rec[1])
                and rec[1] >= 0
            )
        ]
        for mid in stale:
            del msgs[mid]
        dropped += len(stale)
        entry["msgs"] = msgs
        if not msgs and not _path_exists(path):
            del index["files"][path]
            dropped += 1
    return dropped


def prune_session_caches(now_ts=None, max_age_days=SESSION_CACHE_TTL_DAYS):
    """删掉长期未更新的单会话缓存，返回删除个数。

    每个会话都会在 CACHE_DIR 下留一个 <16 位 hash>.json，只增不减。这里按
    mtime 清掉早就不用的；正在用的会话每次渲染都会重写缓存、mtime 跟着刷新，
    所以扫不到它。用文件名长度区分，不会误删 usage-index.json。
    """
    now = time.time() if now_ts is None else now_ts
    cutoff = now - max_age_days * 86400
    try:
        names = os.listdir(CACHE_DIR)
    except OSError:
        return 0
    removed = 0
    for name in names:
        stem, ext = os.path.splitext(name)
        # 崩溃/被杀时遗留的原子写临时文件（mkstemp 生成的 *.tmp）
        is_tmp = ext == ".tmp"
        if not is_tmp and (ext != ".json" or len(stem) != 16):
            continue
        path = os.path.join(CACHE_DIR, name)
        try:
            if os.path.getmtime(path) < (now - 86400 if is_tmp else cutoff):
                os.remove(path)
                removed += 1
        except OSError:
            continue
    return removed


def sweep_session_caches_once_a_day():
    """每天最多清一次，省得每次渲染都列一遍目录。"""
    now = time.time()
    try:
        if now - os.path.getmtime(SESSION_CACHE_SWEEP_MARK) < 86400:
            return
    except OSError:
        pass
    prune_session_caches(now)
    try:
        with open(SESSION_CACHE_SWEEP_MARK, "w", encoding="utf-8") as f:
            f.write(str(int(now)))
    except OSError:
        pass


def _canonical_transcript_path(path):
    absolute = os.path.abspath(path)
    raw = absolute.encode("utf-8", "surrogateescape")
    return os.path.normcase(raw.decode("utf-8", "surrogateescape"))


def _path_exists(path):
    if os.name != "nt":
        path = path.encode("utf-8", "surrogateescape")
    return os.path.exists(path)


def _usage_record_key(rec):
    if isinstance(rec, list) and len(rec) >= 2:
        ts = rec[0] if _is_num(rec[0]) else -1
        total = rec[1] if _is_int(rec[1]) and rec[1] >= 0 else -1
        return total, ts
    return -1, -1


def merge_usage_index_paths(index):
    """统一 locale 相关的路径表示，并合并旧索引里的同一文件条目。"""
    merged_files = {}
    dirty = False
    for path, entry in index["files"].items():
        canonical = _canonical_transcript_path(path)
        if canonical != path:
            dirty = True
        if canonical not in merged_files:
            merged_files[canonical] = entry
            continue
        dirty = True
        current = merged_files[canonical]
        if not isinstance(current, dict):
            current = {"offset": 0, "msgs": {}}
            merged_files[canonical] = current
        if not isinstance(entry, dict):
            continue
        offset = entry.get("offset", 0)
        current_offset = current.get("offset", 0)
        if not _is_int(current_offset) or current_offset < 0:
            current_offset = 0
        if _is_int(offset) and offset > current_offset:
            current["offset"] = offset
        msgs = current.get("msgs")
        if not isinstance(msgs, dict):
            msgs = {}
            current["msgs"] = msgs
        incoming = entry.get("msgs")
        if isinstance(incoming, dict):
            for mid, rec in incoming.items():
                if mid not in msgs or _usage_record_key(rec) > _usage_record_key(msgs[mid]):
                    msgs[mid] = rec
    index["files"] = merged_files
    return dirty


def usage_totals():
    """返回 (今日总 token, 自上次重置以来总 token)。

    统计口径为 input + output + cache_creation + cache_read。索引覆盖
    ~/.claude/projects 下的全部 transcript，并通过 usage-index 做增量扫描。
    """
    now = datetime.datetime.now().astimezone()
    midnight = datetime.datetime.combine(now.date(), datetime.time.min)
    today_start = midnight.astimezone().timestamp()

    reset_ts = read_reset_ts()
    if reset_ts is None:
        reset_ts = now.timestamp()
        try:
            write_reset_ts(reset_ts)
        except OSError:
            pass

    os.makedirs(CACHE_DIR, exist_ok=True)
    lock_file = None
    try:
        if fcntl is not None:
            lock_file = open(USAGE_LOCK, "w", encoding="utf-8")
            try:
                # 拿不到锁就退回读盘上的旧索引：状态栏晚一拍更新可以接受，
                # 卡在别人后面等（甚至等一个卡死的进程）不行。
                fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return totals_from_index(load_usage_index(), today_start, reset_ts)

        index = load_usage_index()
        dirty = merge_usage_index_paths(index)
        pattern = os.path.join(TRANSCRIPT_ROOT, "**", "*.jsonl")
        for path in glob.glob(pattern, recursive=True):
            # 先确认文件还在再建条目：glob 与 getsize 之间文件被删时，
            # 不能留下空条目并白白触发一次整体重写。
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            key = _canonical_transcript_path(path)
            entry = index["files"].get(key)
            if not isinstance(entry, dict):
                entry = {"offset": 0, "msgs": {}}
                index["files"][key] = entry
            if size == entry.get("offset"):
                continue
            new_offset, msgs, changed = scan_usage_file(path, entry)
            if changed:
                entry["offset"] = new_offset
                entry["msgs"] = msgs
                dirty = True

        if prune_index(index, min(today_start, reset_ts)):
            dirty = True
        sweep_session_caches_once_a_day()
        if dirty:
            try:
                save_usage_index(index)
            except OSError:
                pass

        return totals_from_index(index, today_start, reset_ts)
    finally:
        if lock_file is not None:
            try:
                if fcntl is not None:
                    fcntl.flock(lock_file, fcntl.LOCK_UN)
            finally:
                lock_file.close()


def reset_usage():
    ts = time.time()
    write_reset_ts(ts)
    when = datetime.datetime.fromtimestamp(
        ts, tz=datetime.timezone.utc
    ).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    print(f"token 统计已重置：{when}")


def fmt_tokens(n):
    # 阈值取「四舍五入后不会进位成 1000」的点：999_999 应显示 1.0M 而非 1000.0k
    if n >= 999_950_000:
        return f"{n / 1_000_000_000:.1f}B"
    if n >= 999_950:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def track_transcript(tp, api_ms, use_cache=True):
    """增量读取 transcript，维护单会话缓存，返回统计字典。

    返回键：total_out（transcript 累计 output）、turn_out/turn_ms（本轮）、
    avg_out/avg_ms（会话累计 output 与 API 耗时，用于算平均）。
    """
    key_source = tp if isinstance(tp, bytes) else tp.encode("utf-8", "surrogatepass")
    key = hashlib.sha256(key_source).hexdigest()[:16]
    cache_path = os.path.join(CACHE_DIR, key + ".json")
    state = load_cache(cache_path) if use_cache else {"offset": 0, "msgs": {}}
    fresh = "base_api_ms" not in state
    dirty = False
    skip_save = False
    try:
        size = os.path.getsize(tp)
        if size < state["offset"]:
            state = {"offset": 0, "msgs": {}}
            fresh = True
            dirty = True
        new_prompt = base_at_prompt = None
        # scan_new 会就地更新 msgs：先记下扫描前总量，才能判断本块内
        # 新提问前有没有「旧轮次」输出，并让 base_api_ms 与 base_out 对齐同一时刻。
        prev_out = sum(state["msgs"].values())
        if size != state["offset"]:
            offset, new_prompt, base_at_prompt = scan_new(
                tp, state["offset"], state["msgs"]
            )
            if offset != state["offset"]:
                state["offset"] = offset
                dirty = True
        total_out = sum(state["msgs"].values())

        if fresh:
            # 平均直接使用两个会话累计值，无需 avg_base。这里只初始化本轮基线：
            # 首轮流式且 api_ms=0 时不能吞掉首条回复；恢复历史时从此刻起算本轮。
            if api_ms == 0:
                is_first_turn_stream = (
                    base_at_prompt == 0
                    or (base_at_prompt is None and len(state["msgs"]) <= 1)
                )
                state["base_out"] = 0 if is_first_turn_stream else total_out
                state["base_api_ms"] = 0
            else:
                state["base_api_ms"] = api_ms
                state["base_out"] = total_out
            if new_prompt:
                state["prompt"] = new_prompt
            dirty = True
        else:
            last_api = state.get("last_api_ms", state["base_api_ms"])
            base_api = state["base_api_ms"]
            if api_ms == 0 and last_api > 0:
                # 瞬时空 cost 帧或 --resume 首帧：绝不覆写已存基线，也不写盘；
                # 仅返回实时 total_out，等下一个有效 api_ms 再判定是否续跑或重启。
                skip_save = True
                return {
                    "total_out": total_out,
                    "turn_out": 0,
                    "turn_ms": 0,
                    "avg_out": 0,
                    "avg_ms": 0,
                }
            if (
                last_api == 0
                and base_api == 0
                and (
                    state["base_out"] > 0
                    or (api_ms > 0 and total_out == prev_out and prev_out > 0)
                )
            ):
                # 已识别的历史，或首次收到正耗时但已有输出未增长：同时对齐
                # 两条基线，排除该帧之前的累计值。已识别历史的同帧新输出也
                # 一起进入基线；单轮且同帧有新增时，仍沿用首轮流式口径。
                state["base_api_ms"] = api_ms
                state["base_out"] = total_out
                if new_prompt:
                    state["prompt"] = new_prompt
                dirty = True
            elif (
                api_ms < last_api
                and total_out == prev_out
                and new_prompt is None
                and api_ms > last_api * 0.5
            ):
                # 并发乱序的旧刷新帧（无新输出、api_ms 仅小幅落后于已落盘新帧）：
                # 不触发 reset，也不覆写缓存。
                skip_save = True
            elif api_ms < last_api or api_ms < base_api:
                # 会话累计值正常只增不减；异常回退时只重置本轮基线。
                # --resume 恢复的累计值不构成回退，平均始终用 total_out/api_ms。
                if base_at_prompt is not None and base_at_prompt == prev_out:
                    state["base_api_ms"] = 0
                    state["base_out"] = prev_out
                elif base_at_prompt is None:
                    state["base_api_ms"] = 0
                    state["base_out"] = prev_out
                else:
                    # 本块在新提问前还混有旧轮次输出：分子与分母同时对齐到「此刻」。
                    state["base_api_ms"] = api_ms
                    state["base_out"] = total_out
                if new_prompt:
                    state["prompt"] = new_prompt
                dirty = True
            elif new_prompt and new_prompt != state.get("prompt"):
                # 新一轮开始：base_api_ms 与 base_out 必须对应同一时间点。
                # 同一块里 prompt 之后的 assistant 输出属于本轮。
                state["prompt"] = new_prompt
                prompt_base = (
                    base_at_prompt if base_at_prompt is not None else total_out
                )
                if api_ms == last_api:
                    # api 时长尚未计入本块新输出：两者都停在提问时刻。
                    state["base_api_ms"] = api_ms
                    state["base_out"] = prompt_base
                elif prompt_base == prev_out and total_out > prompt_base:
                    # api 已增长，提问前无旧轮次输出且本块确有本轮回复：
                    # 增长来自本轮首条回复，基线回到增长前的同一时刻。
                    state["base_api_ms"] = last_api
                    state["base_out"] = prompt_base
                else:
                    # 本块混杂旧轮次输出：无法归因，退到此刻对齐。
                    state["base_api_ms"] = api_ms
                    state["base_out"] = total_out
                dirty = True
        if not skip_save:
            if state.get("last_api_ms") != api_ms:
                state["last_api_ms"] = api_ms
                dirty = True
            if dirty and use_cache:
                try:
                    save_cache(cache_path, state)
                except OSError:
                    pass
    except OSError:
        pass

    total_out = sum(state["msgs"].values())
    if "base_api_ms" not in state:
        return {"total_out": total_out or None}
    return {
        "total_out": total_out,
        "turn_out": total_out - state["base_out"],
        "turn_ms": api_ms - state["base_api_ms"],
        "avg_out": total_out,
        "avg_ms": api_ms,
    }


def main(no_cache=False):
    _force_utf8_stdio()
    data = _read_stdin_json()
    if not isinstance(data, dict):
        return

    tp = data.get("transcript_path")
    cost = _dict(data.get("cost"))
    ctx = _dict(data.get("context_window"))
    name = _dict(data.get("model")).get("display_name")
    model = name if isinstance(name, str) else ""

    api_raw = cost.get("total_api_duration_ms")
    api_ms = api_raw if _is_num(api_raw) and api_raw > 0 else 0

    stats = {}
    if isinstance(tp, str) and tp:
        tp = os.path.expanduser(tp)
        candidates = [tp]
        if os.name != "nt":
            # C locale 下 Python 3 的文件系统编码可能是 ASCII；同一路径的
            # UTF-8 bytes 形式仍可正常 open/stat，且与字符串形式共用缓存键。
            candidates.append(tp.encode("utf-8", "surrogatepass"))
        for candidate in candidates:
            try:
                if os.path.isfile(candidate):
                    stats = track_transcript(candidate, api_ms, use_cache=not no_cache)
                    break
            except Exception:
                stats = {}

    total_out = stats.get("total_out")
    turn_out = stats.get("turn_out")
    turn_ms = stats.get("turn_ms")
    avg_out = stats.get("avg_out", total_out)
    avg_ms = stats.get("avg_ms", api_ms)

    if total_out is None:
        fallback = ctx.get("total_output_tokens")
        total_out = fallback if _is_int(fallback) and fallback > 0 else 0
        avg_out = total_out
        avg_ms = api_ms

    today_tokens = reset_tokens = None
    if not no_cache:
        try:
            today_tokens, reset_tokens = usage_totals()
        except Exception:
            # 统计失败不能影响状态栏本身
            pass

    parts = []
    turn_speed = None
    if turn_ms is not None and turn_ms >= TURN_MIN_MS and (turn_out or 0) > 0:
        turn_speed = turn_out / (turn_ms / 1000)

    if turn_speed is not None:
        parts.append(f"⏱ 本轮 {turn_speed:.1f} tok/s")
    # 本轮刚起步（不足 TURN_MIN_MS）或还没产出时整段不显示：
    # 每轮开头先闪一个 "--" 纯属噪声。

    if avg_ms is not None and avg_ms > 0 and avg_out:
        parts.append(f"平均 {avg_out / (avg_ms / 1000):.1f} tok/s")

    parts.append(f"{fmt_tokens(total_out)} out")
    if today_tokens is not None:
        parts.append(f"今日 {fmt_tokens(today_tokens)} tok")
        parts.append(f"自重置 {fmt_tokens(reset_tokens)} tok")

    used = ctx.get("used_percentage")
    if _is_num(used):
        parts.append(f"ctx {used:.0f}%")

    if model:
        parts.append(model)

    print(" · ".join(parts))


if __name__ == "__main__":
    _force_utf8_stdio()
    usage = "用法: statusline-tokens.py [--reset | --no-cache]"
    if len(sys.argv) == 1:
        main()
    elif len(sys.argv) == 2 and sys.argv[1] == "--no-cache":
        main(no_cache=True)
    elif len(sys.argv) == 2 and sys.argv[1] == "--reset":
        reset_usage()
    elif len(sys.argv) == 2 and sys.argv[1] in ("-h", "--help"):
        print(usage)
        print("  --reset    将“自重置”token 计数起点设为当前时间")
        print("  --no-cache 只读试跑，不读写缓存、索引或重置文件")
    else:
        print(usage, file=sys.stderr)
        print(f"未知参数：{' '.join(sys.argv[1:])}", file=sys.stderr)
        sys.exit(2)
