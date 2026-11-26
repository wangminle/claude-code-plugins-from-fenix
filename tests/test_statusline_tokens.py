"""statusline-tokens.py / tasklist_sync_reminder.sh 回归测试（BUG-003 ~ BUG-012）。

运行：python3 -m unittest discover -s tests -v
"""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(
    ROOT, "1-claude中显示实时解码速度和累积用量", "statusline-tokens.py"
)
HOOK = os.path.join(ROOT, ".claude", "hooks", "tasklist_sync_reminder.sh")


def load_module():
    spec = importlib.util.spec_from_file_location("statusline_tokens", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def user_line(prompt_id, text="hi", source="typed"):
    return json.dumps(
        {
            "type": "user",
            "promptId": prompt_id,
            "promptSource": source,
            "message": {"role": "user", "content": text},
        }
    )


def assistant_line(mid, out, ts="2026-11-15T10:00:00Z"):
    return json.dumps(
        {
            "type": "assistant",
            "timestamp": ts,
            "message": {
                "id": mid,
                "usage": {"input_tokens": 1, "output_tokens": out},
            },
        }
    )


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.m = load_module()
        cache = os.path.join(self.tmp, "cache")
        self.m.CACHE_DIR = cache
        self.m.USAGE_INDEX = os.path.join(cache, "usage-index.json")
        self.m.USAGE_LOCK = os.path.join(cache, "usage-index.lock")
        self.m.SESSION_CACHE_SWEEP_MARK = os.path.join(cache, "last-sweep")
        self.m.RESET_FILE = os.path.join(self.tmp, "reset.json")
        self.m.TRANSCRIPT_ROOT = os.path.join(self.tmp, "projects")
        self.transcript = os.path.join(self.tmp, "s.jsonl")

    def append(self, *lines):
        with open(self.transcript, "a", encoding="utf-8") as f:
            for line in lines:
                f.write(line + "\n")

    def run_main(self, payload, raw=None):
        text = raw if raw is not None else json.dumps(payload)
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(text)):
            with contextlib.redirect_stdout(out):
                self.m.main()
        return out.getvalue()

    def render(self, api_ms, **extra):
        payload = {
            "transcript_path": self.transcript,
            "cost": {"total_api_duration_ms": api_ms},
        }
        payload.update(extra)
        return self.run_main(payload)

    def cache_state(self):
        key = self.m.hashlib.sha256(self.transcript.encode()).hexdigest()[:16]
        with open(os.path.join(self.m.CACHE_DIR, key + ".json")) as f:
            return json.load(f)


class TestBug003BaselineSwallowsTokens(Base):
    def test_scan_new_reports_total_at_prompt(self):
        self.append(
            assistant_line("a", 50),
            user_line("p1"),
            assistant_line("b", 100),
        )
        msgs = {}
        result = self.m.scan_new(self.transcript, 0, msgs)
        _, last_prompt, base = result
        self.assertEqual(last_prompt, "p1")
        self.assertEqual(base, 50)
        self.assertEqual(sum(msgs.values()), 150)

    def test_new_output_in_same_chunk_not_swallowed(self):
        self.append(assistant_line("a", 50))
        self.render(1000)  # 建立基线
        self.append(user_line("p1"), assistant_line("b", 100))
        out = self.render(1000)  # 提问与回复被同一块读到，api 时长尚未增长
        self.assertEqual(self.cache_state()["base_out"], 50)
        out = self.render(3000)
        self.assertIn("本轮 50.0 tok/s", out)


class TestBug004ApiDurationReset(Base):
    def test_average_not_inflated_after_resume(self):
        self.append(assistant_line("a", 100000))
        self.render(50000)
        out = self.render(500)  # 新进程：api 时长从 0 重新累计
        self.assertNotIn("平均", out)
        self.assertIn("100.0k out", out)
        self.append(assistant_line("b", 100))
        out = self.render(2000)
        self.assertIn("平均 50.0 tok/s", out)
        self.assertNotIn("本轮 -", out)

    def test_old_cache_without_last_api_ms_detects_reset(self):
        self.append(assistant_line("a", 109654))
        key = self.m.hashlib.sha256(self.transcript.encode()).hexdigest()[:16]
        os.makedirs(self.m.CACHE_DIR, exist_ok=True)
        size = os.path.getsize(self.transcript)
        with open(os.path.join(self.m.CACHE_DIR, key + ".json"), "w") as f:
            json.dump(
                {
                    "offset": size,
                    "msgs": {"a": 109654},
                    "base_out": 109654,
                    "base_api_ms": 1000,
                },
                f,
            )
        out = self.render(500)
        self.assertNotIn("109654.0", out)
        self.assertNotIn("平均", out)


class TestBug005Tilde(Base):
    def test_tilde_transcript_path_expanded(self):
        home = os.path.join(self.tmp, "home")
        os.makedirs(home)
        self.transcript = os.path.join(home, "t.jsonl")
        self.append(assistant_line("a", 2000))
        with mock.patch.dict(os.environ, {"HOME": home, "USERPROFILE": home}):
            out = self.run_main(
                {
                    "transcript_path": "~/t.jsonl",
                    "cost": {"total_api_duration_ms": 1000},
                }
            )
        self.assertIn("2.0k out", out)

    def test_non_string_transcript_path_ignored(self):
        out = self.run_main({"transcript_path": 123, "cost": {}})
        self.assertIn("0 out", out)


class TestBug006Robustness(Base):
    def test_load_cache_bad_shapes(self):
        path = os.path.join(self.tmp, "c.json")
        blank = {"offset": 0, "msgs": {}}
        for raw in ("null", "[]", "3", '{"offset":true,"msgs":{}}',
                    '{"offset":-5,"msgs":{}}', "{bad"):
            with open(path, "w") as f:
                f.write(raw)
            self.assertEqual(self.m.load_cache(path), blank, raw)

    def test_load_cache_filters_bad_msgs(self):
        path = os.path.join(self.tmp, "c.json")
        with open(path, "w") as f:
            json.dump(
                {"offset": 5, "msgs": {"a": 3, "b": -1, "c": True, "d": "x"}}, f
            )
        state = self.m.load_cache(path)
        self.assertEqual(state["msgs"], {"a": 3})

    def test_main_stdin_bad_shapes(self):
        for raw in ("null", "[]", '"x"', "{", "",
                    '{"model":"claude-opus-5"}',
                    '{"cost":[],"context_window":"x","model":[]}',
                    '{"transcript_path":["a"]}'):
            self.run_main(None, raw=raw)  # 不得抛异常

    def test_main_corrupt_null_cache_does_not_crash(self):
        self.append(assistant_line("a", 10))
        key = self.m.hashlib.sha256(self.transcript.encode()).hexdigest()[:16]
        os.makedirs(self.m.CACHE_DIR, exist_ok=True)
        with open(os.path.join(self.m.CACHE_DIR, key + ".json"), "w") as f:
            f.write("null")
        out = self.render(1000)
        self.assertIn("10 out", out)

    def test_bool_is_not_a_number(self):
        out = self.run_main(
            {"context_window": {"used_percentage": True}, "cost": {}}
        )
        self.assertNotIn("ctx", out)
        out = self.run_main(
            {"cost": {"total_api_duration_ms": True},
             "context_window": {"total_output_tokens": True}}
        )
        self.assertIn("0 out", out)

    def test_index_and_reset_null(self):
        os.makedirs(self.m.CACHE_DIR, exist_ok=True)
        for p in (self.m.USAGE_INDEX, self.m.RESET_FILE):
            with open(p, "w") as f:
                f.write("null")
        self.assertEqual(self.m.load_usage_index(), {"v": 1, "files": {}})
        self.assertIsNone(self.m.read_reset_ts())
        self.m.usage_totals()  # 不得抛异常

    def test_index_bad_entries(self):
        index = {"v": 1, "files": {"/x": None, "/y": [], "/z": {"msgs": 3}}}
        self.assertEqual(self.m.totals_from_index(index, 0, 0), (0, 0))
        self.m.prune_index(index, 0)

    def test_transcript_lines_with_non_dict_values(self):
        self.append(
            "null", "[]", "3",
            json.dumps({"type": "assistant", "message": "str"}),
            json.dumps({"type": "assistant", "message": {"usage": []}}),
            json.dumps({"type": "user", "message": 7, "promptSource": "typed"}),
            assistant_line("a", 5),
        )
        msgs = {}
        self.m.scan_new(self.transcript, 0, msgs)
        self.assertEqual(msgs, {"a": 5})
        _, msgs2, _ = self.m.scan_usage_file(
            self.transcript, {"offset": 0, "msgs": {}}
        )
        self.assertIn("a", msgs2)


class TestBug007AtomicWrite(Base):
    def test_concurrent_save_cache(self):
        path = os.path.join(self.m.CACHE_DIR, "0123456789abcdef.json")
        errors = []

        def worker(n):
            try:
                for i in range(60):
                    self.m.save_cache(path, {"offset": i, "msgs": {"k": n}})
            except Exception as e:  # noqa: BLE001
                errors.append(repr(e))

        threads = [threading.Thread(target=worker, args=(n,)) for n in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        with open(path) as f:
            json.load(f)
        self.assertEqual(
            [n for n in os.listdir(self.m.CACHE_DIR) if n.endswith(".tmp")], []
        )

    def test_no_fixed_tmp_names(self):
        seen = []
        real_replace = os.replace

        def spy(src, dst):
            seen.append(src)
            return real_replace(src, dst)

        with mock.patch("os.replace", spy):
            self.m.save_cache(os.path.join(self.m.CACHE_DIR, "a.json"), {})
            self.m.write_reset_ts(1.0)
            self.m.save_usage_index({"v": 1, "files": {}})
        for src, dst in zip(seen, ["a.json", "reset.json", "usage-index.json"]):
            self.assertNotEqual(src, os.path.join(os.path.dirname(src), dst + ".tmp"))

    def test_stale_tmp_files_swept(self):
        os.makedirs(self.m.CACHE_DIR, exist_ok=True)
        stale = os.path.join(self.m.CACHE_DIR, "x.json.abc.tmp")
        with open(stale, "w") as f:
            f.write("{")
        old = 1_000_000
        os.utime(stale, (old, old))
        self.m.prune_session_caches()
        self.assertFalse(os.path.exists(stale))


class TestBug008Encoding(Base):
    def test_c_locale_with_non_ascii(self):
        home = os.path.join(self.tmp, "home")
        proj = os.path.join(home, ".claude", "projects", "中文项目")
        os.makedirs(proj)
        tp = os.path.join(proj, "会话.jsonl")
        with open(tp, "w", encoding="utf-8") as f:
            f.write(assistant_line("a", 1200) + "\n")
        env = dict(os.environ)
        env.update(
            HOME=home,
            USERPROFILE=home,
            XDG_CACHE_HOME=os.path.join(home, "cache"),
            LC_ALL="C",
            LANG="C",
            PYTHONUTF8="0",
            PYTHONCOERCECLOCALE="0",
            PYTHONIOENCODING="cp1252",
        )
        payload = {
            "transcript_path": tp,
            "cost": {"total_api_duration_ms": 1000},
            "model": {"display_name": "模型甲"},
        }
        proc = subprocess.run(
            [sys.executable, SCRIPT],
            input=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            capture_output=True,
            env=env,
        )
        err = proc.stderr.decode("utf-8", "replace")
        self.assertEqual(proc.returncode, 0, err)
        out = proc.stdout.decode("utf-8")
        self.assertIn("今日", out)
        self.assertIn("模型甲", out)
        self.assertIn("1.2k out", out)


class TestBug009Edges(Base):
    def test_fmt_tokens_rounding_carry(self):
        f = self.m.fmt_tokens
        self.assertEqual(f(999), "999")
        self.assertEqual(f(1000), "1.0k")
        self.assertEqual(f(999_949), "999.9k")
        self.assertEqual(f(999_999), "1.0M")
        self.assertEqual(f(999_949_999), "999.9M")
        self.assertEqual(f(999_999_999), "1.0B")
        self.assertEqual(f(2_500_000_000), "2.5B")

    def test_vanished_file_does_not_dirty_index(self):
        with mock.patch.object(
            self.m.glob, "glob", return_value=["/nonexistent/x.jsonl"]
        ):
            self.m.usage_totals()
        self.assertFalse(os.path.exists(self.m.USAGE_INDEX))


@unittest.skipUnless(shutil.which("bash"), "需要 bash")
class TestHook(unittest.TestCase):
    def run_hook(self, session_id, tmpdir):
        env = dict(os.environ, TMPDIR=tmpdir)
        return subprocess.run(
            ["bash", HOOK],
            input=json.dumps({"session_id": session_id}).encode(),
            capture_output=True,
            env=env,
        )

    def test_session_id_sanitized_and_once_per_session(self):
        tmpdir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmpdir, ignore_errors=True)
        first = self.run_hook("../../evil/x", tmpdir)
        self.assertEqual(first.returncode, 0, first.stderr)
        data = json.loads(first.stdout.decode("utf-8"))
        self.assertEqual(data["decision"], "block")
        names = os.listdir(tmpdir)
        self.assertEqual(len(names), 1, names)
        self.assertTrue(names[0].startswith("claude-tasklist-sync-"))
        self.assertNotIn("/", names[0])
        self.assertFalse(os.path.exists(os.path.join(tmpdir, "..", "evil")))
        second = self.run_hook("../../evil/x", tmpdir)
        self.assertEqual(second.stdout, b"")

    def test_output_is_ascii_json(self):
        tmpdir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmpdir, ignore_errors=True)
        proc = self.run_hook("abc", tmpdir)
        proc.stdout.decode("ascii")  # ensure_ascii：任何管道编码都安全


class TestBug010BaselineTimeMismatch(Base):
    def test_same_chunk_prompt_and_reply_does_not_inflate_turn_speed(self):
        # 第 1 轮：建立基线
        self.append(user_line("p1"), assistant_line("a", 100))
        self.render(10_000)
        # 第 2 轮：提问 + 首条回复同块读入，且 api_ms 已计入该回复耗时
        self.append(user_line("p2"), assistant_line("b", 1000))
        out = self.render(30_000)
        self.assertIn("本轮 50.0 tok/s", out)
        state = self.cache_state()
        self.assertEqual(state["base_api_ms"], 10_000)
        self.assertEqual(state["base_out"], 100)
        # 工具调用后再出第 2 条回复：真实 1050/21s = 50.0
        self.append(assistant_line("c", 50))
        out = self.render(31_000)
        self.assertIn("本轮 50.0 tok/s", out)
        self.assertNotIn("1050.0 tok/s", out)

    def test_resume_same_chunk_prompt_and_reply_aligned(self):
        self.append(user_line("p1"), assistant_line("a", 5000))
        self.render(60_000)
        # --resume：api 回退；同块读到新提问 + 首条回复
        self.append(user_line("p3"), assistant_line("b", 1000))
        out = self.render(20_000)
        self.assertIn("本轮 50.0 tok/s", out)
        self.append(assistant_line("c", 50))
        out = self.render(21_000)
        self.assertIn("本轮 50.0 tok/s", out)
        self.assertNotIn("1050.0 tok/s", out)


class TestBug011ResumeAvgWithoutPrompt(Base):
    def test_resume_output_without_new_prompt_keeps_average(self):
        self.append(assistant_line("hist", 100000))
        self.render(50_000)
        # 恢复后无新提问，直接产出回复
        self.append(assistant_line("b", 1000))
        out = self.render(10_000)
        self.assertIn("平均 100.0 tok/s", out)
        self.append(assistant_line("c", 200))
        out = self.render(12_000)
        self.assertIn("平均 100.0 tok/s", out)
        self.assertNotIn("平均 16.7 tok/s", out)

    def test_api_ms_below_base_api_ms_resets_baseline(self):
        self.append(assistant_line("a", 100))
        self.render(10_000)
        key = self.m.hashlib.sha256(self.transcript.encode()).hexdigest()[:16]
        path = os.path.join(self.m.CACHE_DIR, key + ".json")
        with open(path, encoding="utf-8") as f:
            state = json.load(f)
        # 模拟异常缓存：last_api_ms 已更新，但仍小于 base_api_ms
        state["base_api_ms"] = 10_000
        state["last_api_ms"] = 2_000
        with open(path, "w", encoding="utf-8") as f:
            json.dump(state, f)
        self.append(assistant_line("b", 300))
        out = self.render(3_000)
        self.assertNotIn("本轮 -", out)
        stats = self.m.track_transcript(self.transcript, 3_000)
        self.assertGreaterEqual(stats["turn_ms"], 0)


class TestBug012UsageTotalsResilience(Base):
    def test_save_usage_index_oserror_keeps_totals(self):
        # 重置点早于消息时间，否则「自重置」会被刚写入的 now 截成 0
        self.m.write_reset_ts(1_700_000_000)
        proj = os.path.join(self.m.TRANSCRIPT_ROOT, "p")
        os.makedirs(proj)
        path = os.path.join(proj, "t.jsonl")
        now_iso = self.m.datetime.datetime.now().astimezone().isoformat()
        with open(path, "w", encoding="utf-8") as f:
            f.write(
                json.dumps(
                    {
                        "type": "assistant",
                        "timestamp": now_iso,
                        "message": {
                            "id": "m1",
                            "usage": {
                                "input_tokens": 10,
                                "output_tokens": 20,
                                "cache_creation_input_tokens": 0,
                                "cache_read_input_tokens": 0,
                            },
                        },
                    }
                )
                + "\n"
            )
        with mock.patch.object(
            self.m, "save_usage_index", side_effect=PermissionError("locked")
        ):
            today, reset = self.m.usage_totals()
        self.assertEqual(today, 30)
        self.assertEqual(reset, 30)

    def test_fcntl_none_does_not_open_lock_file(self):
        real_open = open
        opened = []

        def tracking_open(path, *args, **kwargs):
            opened.append(path)
            return real_open(path, *args, **kwargs)

        with mock.patch.object(self.m, "fcntl", None):
            with mock.patch("builtins.open", side_effect=tracking_open):
                self.m.usage_totals()
        self.assertNotIn(self.m.USAGE_LOCK, opened)

    def test_parse_ts_overflow_returns_none(self):
        self.assertIsNone(self.m.parse_ts("not-a-date"))

        class BoomDT:
            @staticmethod
            def fromisoformat(_value):
                class Boom:
                    def timestamp(self):
                        raise OverflowError("too big")

                return Boom()

        orig = self.m.datetime.datetime
        self.m.datetime.datetime = BoomDT
        try:
            self.assertIsNone(self.m.parse_ts("2020-01-01T00:00:00Z"))
        finally:
            self.m.datetime.datetime = orig

        class OsErrDT:
            @staticmethod
            def fromisoformat(_value):
                m = mock.Mock()
                m.timestamp.side_effect = OSError("out of range")
                return m

        self.m.datetime.datetime = OsErrDT
        try:
            self.assertIsNone(self.m.parse_ts("1969-01-01T00:00:00Z"))
        finally:
            self.m.datetime.datetime = orig


class TestBug013AverageSpeedResilience(Base):
    def test_first_turn_streaming_with_zero_api_ms_not_treated_as_history(self):
        self.append(user_line("p1"), assistant_line("m1", 200))
        out = self.render(0)
        self.assertIn("200 out", out)
        self.assertNotIn("平均", out)
        self.append(assistant_line("m1", 250))
        out = self.render(5_000)
        self.assertIn("本轮 50.0 tok/s", out)
        self.assertIn("平均 50.0 tok/s", out)

    def test_fresh_multi_turn_history_with_zero_api_ms_treated_as_resume(self):
        self.append(
            user_line("p1"),
            assistant_line("m1", 5000),
            user_line("p2"),
            assistant_line("m2", 3000),
        )
        out = self.render(0)
        self.assertIn("8.0k out", out)
        self.append(user_line("p3"), assistant_line("m3", 100))
        out = self.render(2_000)
        self.assertIn("平均 50.0 tok/s", out)

    def test_transient_empty_cost_frame_does_not_corrupt_baselines(self):
        self.append(assistant_line("m1", 5000))
        self.assertIn("平均 50.0 tok/s", self.render(100_000))
        # 瞬时缺少 cost / api_ms=0 的渲染帧不得重置基线
        out = self.run_main({"transcript_path": self.transcript})
        self.assertIn("5.0k out", out)
        self.append(assistant_line("m2", 100))
        out = self.render(102_000)
        self.assertIn("本轮 50.0 tok/s", out)
        self.assertIn("平均 50.0 tok/s", out)

    def test_stale_concurrent_refresh_does_not_trigger_reset(self):
        self.append(assistant_line("m1", 5000))
        self.render(100_000)
        self.append(assistant_line("m2", 100))
        self.assertIn("平均 50.0 tok/s", self.render(102_000))
        # 并发乱序：旧的 100s 帧晚于 102s 帧到达
        self.render(100_000)
        self.append(assistant_line("m3", 100))
        out = self.render(104_000)
        self.assertIn("本轮 50.0 tok/s", out)
        self.assertIn("平均 50.0 tok/s", out)

    def test_resume_mixed_chunk_pairs_avg_base_api_ms(self):
        self.append(user_line("p1"), assistant_line("m1", 5000))
        self.render(60_000)
        # 恢复时同一块里既含旧轮尾部输出，又含新提问与回复 -> 触发 else 对齐此刻
        self.append(
            assistant_line("m1_tail", 500),
            user_line("p2"),
            assistant_line("m2", 500),
        )
        out = self.render(20_000)
        self.assertNotIn("平均", out)
        # 后续新增 500 tok / 10s：分母应扣掉 20s，算得 50.0 tok/s 而非 16.7 tok/s
        self.append(assistant_line("m3", 500))
        out = self.render(30_000)
        self.assertIn("平均 50.0 tok/s", out)
        self.assertNotIn("平均 16.7 tok/s", out)


class TestBug014TurnAndCliEdges(Base):
    def test_prompt_without_output_does_not_reuse_previous_turn_api_time(self):
        self.append(user_line("p1"), assistant_line("a", 100))
        self.render(1_000)
        self.append(user_line("p2"))
        self.render(3_000)
        self.append(assistant_line("b", 200))
        out = self.render(5_000)
        self.assertIn("本轮 100.0 tok/s", out)
        self.assertNotIn("本轮 50.0 tok/s", out)

    def test_fresh_resume_with_history_does_not_inflate_average(self):
        self.append(
            user_line("p1"),
            assistant_line("a", 5000),
            user_line("p2"),
            assistant_line("b", 3000),
        )
        out = self.render(2_000)
        self.assertNotIn("平均", out)
        state = self.cache_state()
        self.assertEqual(state["avg_base_out"], 8000)
        self.assertEqual(state["avg_base_api_ms"], 2000)
        self.append(assistant_line("c", 100))
        out = self.render(4_000)
        self.assertIn("平均 50.0 tok/s", out)

    def test_unknown_arguments_exit_without_reading_stdin(self):
        proc = subprocess.run(
            [sys.executable, SCRIPT, "--rest"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("用法", proc.stderr.decode("utf-8"))
        self.assertIn("--rest", proc.stderr.decode("utf-8"))

    def test_negative_usage_fields_do_not_cancel_output(self):
        line = json.dumps(
            {
                "type": "assistant",
                "timestamp": "2026-11-26T10:00:00Z",
                "message": {
                    "id": "negative",
                    "usage": {
                        "input_tokens": -100,
                        "output_tokens": 10,
                        "cache_creation_input_tokens": -20,
                        "cache_read_input_tokens": -30,
                    },
                },
            }
        )
        self.append(line)
        _, msgs, _ = self.m.scan_usage_file(
            self.transcript, {"offset": 0, "msgs": {}}
        )
        self.assertEqual(msgs["negative"][1], 10)


if __name__ == "__main__":
    unittest.main()
