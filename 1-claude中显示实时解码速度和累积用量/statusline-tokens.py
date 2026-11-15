#!/usr/bin/env python3
"""Claude Code status line: 显示会话平均与当前轮次的 token 生成速度。

Claude Code 会通过 stdin 传入一份 JSON，包含 transcript_path、
cost.total_api_duration_ms、context_window 等字段。本脚本增量解析
transcript（JSONL，只读新增部分，结果按文件大小缓存）：

* 平均速度 = 会话累计 output tokens / 会话累计 API 等待时长；
* 本轮速度 = 本轮开始（最近一条用户 prompt 落盘）后新增的 output
  tokens / 本轮累计 API 等待时长（用两次状态栏刷新的 api 时长差估算）；
* 今日 = 本地 0 点至今，所有会话的 input + output + cache token 总量；
* 自重置 = 从上次 `--reset` 起，上述口径的 token 总量。

同一条 assistant 消息在流式过程中会被写入多条 usage 快照，必须按
message.id 去重取最大值，否则会重复计数。跨会话统计使用
usage-index.json 增量索引，并保留每条消息的时间戳以支持按日/按重置点汇总。
"""

import datetime
import fcntl
import glob
import hashlib
import json
import os
import sys
import time

CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "claude-statusline",
)
USAGE_INDEX = os.path.join(CACHE_DIR, "usage-index.json")
USAGE_LOCK = os.path.join(CACHE_DIR, "usage-index.lock")
RESET_FILE = os.path.expanduser("~/.claude/statusline-usage-reset.json")
TRANSCRIPT_ROOT = os.path.expanduser("~/.claude/projects")

TURN_MIN_MS = 800  # 本轮做过短时速度抖动大，先不显示


def load_cache(path):
    try:
        with open(path) as f:
            d = json.load(f)
        if isinstance(d.get("offset"), int) and isinstance(d.get("msgs"), dict):
            return d
    except (OSError, ValueError):
        pass
    return {"offset": 0, "msgs": {}}


def save_cache(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, separators=(",", ":"))
    os.replace(tmp, path)


def scan_new(path, offset, msgs):
    """从 offset 起读取完整行，返回 (新 offset, 本块中最后一条用户 prompt 的 id)。

    用户 prompt 用 promptId 识别（本地命令输出、工具结果都没有该字段）。
    """
    with open(path, "rb") as f:
        f.seek(offset)
        buf = f.read()
    if not buf:
        return offset, None
    last_nl = buf.rfind(b"\n")
    if last_nl < 0:
        return offset, None  # 最后一行还没写完，下次再解析
    last_prompt = None
    for line in buf[: last_nl + 1].splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        typ = obj.get("type")
        if typ == "user":
            # 工具结果条目也带 promptId，必须排除；真实用户提示带
            # promptSource（如 typed），本地命令输出/工具结果没有。
            if obj.get("isMeta") or not obj.get("promptSource"):
                continue
            content = (obj.get("message") or {}).get("content")
            if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result"
                for b in content
            ):
                continue
            pid = obj.get("promptId")
            if pid:
                last_prompt = pid
            continue
        if typ != "assistant" or b'"output_tokens"' not in line:
            continue
        msg = obj.get("message") or {}
        n = (msg.get("usage") or {}).get("output_tokens")
        mid = msg.get("id")
        if not isinstance(n, int) or n <= 0 or not mid:
            continue
        if n > msgs.get(mid, 0):
            msgs[mid] = n
    return offset + last_nl + 1, last_prompt


def _int(value):
    return value if isinstance(value, int) else 0


def parse_ts(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.fromisoformat(
            value.replace("Z", "+00:00")
        ).timestamp()
    except ValueError:
        return None


def read_reset_ts():
    try:
        with open(RESET_FILE) as f:
            data = json.load(f)
        ts = data.get("reset_ts")
        if isinstance(ts, (int, float)) and ts > 0:
            return float(ts)
    except (OSError, ValueError, TypeError):
        pass
    return None


def write_reset_ts(ts):
    os.makedirs(os.path.dirname(RESET_FILE), exist_ok=True)
    tmp = RESET_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(
            {
                "reset_ts": ts,
                "reset_at": datetime.datetime.fromtimestamp(ts)
                .astimezone()
                .isoformat(),
            },
            f,
            ensure_ascii=False,
        )
    os.replace(tmp, RESET_FILE)


def load_usage_index():
    try:
        with open(USAGE_INDEX) as f:
            data = json.load(f)
        if data.get("v") == 1 and isinstance(data.get("files"), dict):
            return data
    except (OSError, ValueError):
        pass
    return {"v": 1, "files": {}}


def save_usage_index(index):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = USAGE_INDEX + ".tmp"
    with open(tmp, "w") as f:
        json.dump(index, f, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp, USAGE_INDEX)


def scan_usage_file(path, entry):
    """增量扫描一个 transcript，返回 (新 offset, 消息表, 是否有变化)。

    消息表按 message.id 去重，保存 [时间戳, 总 token]。同一消息的流式
    快照只保留最大值，避免重复计数。
    """
    offset = entry.get("offset", 0)
    if not isinstance(offset, int) or offset < 0:
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
        if obj.get("type") != "assistant":
            continue
        msg = obj.get("message") or {}
        usage = msg.get("usage") or {}
        mid = msg.get("id")
        out = usage.get("output_tokens")
        if not isinstance(out, int) or out < 0 or not isinstance(mid, str) or not mid:
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
            and isinstance(old[1], int)
            else 0
        )
        if total > old_total:
            msgs[mid] = [ts, total]
            changed = True

    new_offset = offset + last_nl + 1
    if new_offset != offset:
        changed = True
    return new_offset, msgs, changed


def usage_totals():
    """返回 (今日总 token, 自上次重置以来总 token)。

    统计口径为 input + output + cache_creation + cache_read。索引覆盖
    ~/.claude/projects 下的全部 transcript，并通过 usage-index 做增量扫描。
    """
    now = datetime.datetime.now().astimezone()
    today_start = now.replace(
        hour=0, minute=0, second=0, microsecond=0
    ).timestamp()

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
        lock_file = open(USAGE_LOCK, "w")
        fcntl.flock(lock_file, fcntl.LOCK_EX)

        index = load_usage_index()
        dirty = False
        pattern = os.path.join(TRANSCRIPT_ROOT, "**", "*.jsonl")
        for path in glob.glob(pattern, recursive=True):
            entry = index["files"].get(path)
            if not isinstance(entry, dict):
                entry = {"offset": 0, "msgs": {}}
                index["files"][path] = entry
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            if size == entry.get("offset"):
                continue
            new_offset, msgs, changed = scan_usage_file(path, entry)
            if changed:
                entry["offset"] = new_offset
                entry["msgs"] = msgs
                dirty = True
        if dirty:
            save_usage_index(index)

        today = 0
        since_reset = 0
        for entry in index["files"].values():
            for rec in (entry.get("msgs") or {}).values():
                if not isinstance(rec, list) or len(rec) < 2:
                    continue
                ts, total = rec[0], rec[1]
                if not isinstance(ts, (int, float)) or not isinstance(total, int):
                    continue
                if ts >= today_start:
                    today += total
                if ts >= reset_ts:
                    since_reset += total
        return today, since_reset
    finally:
        if lock_file is not None:
            try:
                fcntl.flock(lock_file, fcntl.LOCK_UN)
            finally:
                lock_file.close()


def reset_usage():
    ts = time.time()
    write_reset_ts(ts)
    when = datetime.datetime.fromtimestamp(ts).astimezone().strftime(
        "%Y-%m-%d %H:%M:%S %Z"
    )
    print(f"token 统计已重置：{when}")


def fmt_tokens(n):
    if n >= 1_000_000_000:
        return f"{n / 1_000_000_000:.1f}B"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return

    tp = data.get("transcript_path")
    cost = data.get("cost") or {}
    ctx = data.get("context_window") or {}
    model = (data.get("model") or {}).get("display_name") or ""

    api_ms = cost.get("total_api_duration_ms") or 0
    total_out = None
    turn_out = turn_ms = None

    if tp and os.path.isfile(tp):
        key = hashlib.sha256(tp.encode()).hexdigest()[:16]
        cache_path = os.path.join(CACHE_DIR, key + ".json")
        state = load_cache(cache_path)
        try:
            size = os.path.getsize(tp)
            if size < state["offset"]:
                state = {"offset": 0, "msgs": {}}
            dirty = False
            if size != state["offset"]:
                offset, new_prompt = scan_new(tp, state["offset"], state["msgs"])
                if offset != state["offset"]:
                    state["offset"] = offset
                    dirty = True
                total_now = sum(state["msgs"].values())
                if new_prompt and new_prompt != state.get("prompt"):
                    # 新一轮开始：以本刻的 api 时长和输出总量作为基线
                    state["prompt"] = new_prompt
                    state["base_api_ms"] = api_ms
                    state["base_out"] = total_now
                    dirty = True
            total_out = sum(state["msgs"].values())
            if "base_api_ms" not in state:
                state["base_api_ms"] = api_ms
                state["base_out"] = total_out
                dirty = True
            if dirty:
                save_cache(cache_path, state)
            turn_out = total_out - state.get("base_out", 0)
            turn_ms = api_ms - state.get("base_api_ms", api_ms)
        except OSError:
            total_out = sum(state["msgs"].values()) if state.get("msgs") else None

    if total_out is None:
        total_out = ctx.get("total_output_tokens") or 0

    today_tokens = reset_tokens = None
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
    elif turn_ms is not None:
        parts.append("⏱ 本轮 --")

    if api_ms > 0 and total_out:
        parts.append(f"平均 {total_out / (api_ms / 1000):.1f} tok/s")

    parts.append(f"{fmt_tokens(total_out)} out")
    if today_tokens is not None:
        parts.append(f"今日 {fmt_tokens(today_tokens)} tok")
        parts.append(f"自重置 {fmt_tokens(reset_tokens)} tok")

    used = ctx.get("used_percentage")
    if isinstance(used, (int, float)):
        parts.append(f"ctx {used:.0f}%")

    if model:
        parts.append(model)

    print(" · ".join(parts))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--reset":
        reset_usage()
    elif len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print("用法: statusline-tokens.py [--reset]")
        print("  --reset  将“自重置”token 计数起点设为当前时间")
    else:
        main()
