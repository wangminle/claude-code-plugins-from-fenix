"""fenix-selected-skills.sh / .ps1 的本地端到端回归测试。

默认只跑本机 Bash；跨环境回归按需开启：

    FENIX_TEST_DOCKER_BASH=1  # Docker Bash 5（默认镜像 fenix-selected-skills-bash:test）
    FENIX_TEST_DOCKER_PWSH=1  # Docker PowerShell 7.4（默认镜像 fenix-selected-skills-pwsh:test）

两种 Docker 镜像缺少依赖时，测试会用 tests/Dockerfile.bash / tests/Dockerfile.pwsh
自动构建一次；构建失败（例如离线）时整组跳过并给出原因。也可用
FENIX_BASH_IMAGE / FENIX_PWSH_IMAGE 指定已构建好的镜像。
Windows 本机安装 PowerShell 后还会自动运行 NativeWindowsPowerShellSkillsScriptTest。
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TESTS_DIR = Path(__file__).resolve().parent
SOURCE = ROOT / "2-claude自选skills列表" / "fenix-selected-skills.sh"
DEFAULT_BASH_IMAGE = "fenix-selected-skills-bash:test"
DEFAULT_PWSH_IMAGE = "fenix-selected-skills-pwsh:test"


def image_has_deps(tag):
    probe = subprocess.run(
        ["docker", "run", "--rm", tag, "sh", "-c",
         "command -v git >/dev/null && command -v jq >/dev/null && command -v curl >/dev/null"],
        capture_output=True,
        text=True,
    )
    return probe.returncode == 0


def ensure_docker_image(tag, dockerfile, auto_build=True):
    """确保测试镜像可用且含 git/jq/curl；缺失或残缺时构建，构建不了就跳过整组测试。"""
    try:
        inspect = subprocess.run(
            ["docker", "image", "inspect", tag], capture_output=True, text=True
        )
    except FileNotFoundError:
        raise unittest.SkipTest("未找到 docker 可执行文件")
    if inspect.returncode == 0 and image_has_deps(tag):
        return tag
    if not auto_build:
        raise unittest.SkipTest(f"镜像 {tag} 不存在或缺少 git/jq/curl（FENIX_*_IMAGE 指定后不会自动构建）")
    if os.environ.get("FENIX_NO_DOCKER_BUILD") == "1":
        raise unittest.SkipTest(f"镜像 {tag} 不存在，且设置了 FENIX_NO_DOCKER_BUILD=1")
    build = subprocess.run(
        ["docker", "build", "-t", tag, "-f", str(TESTS_DIR / dockerfile), str(TESTS_DIR)],
        capture_output=True,
        text=True,
    )
    if build.returncode != 0:
        # 部分网络下 BuildKit 的 DNS 拉不动包管理器镜像，退回宿主网络再试一次
        build = subprocess.run(
            ["docker", "build", "--network", "host", "-t", tag,
             "-f", str(TESTS_DIR / dockerfile), str(TESTS_DIR)],
            capture_output=True,
            text=True,
        )
    if build.returncode != 0:
        detail = (build.stderr or build.stdout or "").strip()[-800:]
        raise unittest.SkipTest(f"无法构建测试镜像 {tag}（离线？）：{detail}")
    return tag


def docker_git_path(image):
    proc = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "sh", image, "-c", "command -v git"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise unittest.SkipTest(f"镜像 {image} 内找不到 git")
    return proc.stdout.strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class SkillsScriptTest(unittest.TestCase):
    native_windows = False
    implementation = "bash"

    def setUp(self):
        if self.__class__ is SkillsScriptTest and (os.name == "nt" or not shutil.which("bash")):
            raise unittest.SkipTest("本机 Bash 场景需要非 Windows 环境；Windows 请运行 PowerShell 测试类")
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.remote = self.tmp / "remote"
        self.remote.mkdir()
        self.script = self.tmp / "fenix-selected-skills.sh"
        text = SOURCE.read_text(encoding="utf-8").replace(
            'GITHUB="https://github.com"', f'GITHUB="{self.remote}"'
        )
        self.script.write_text(text, encoding="utf-8")
        self.script.chmod(0o755)
        self.data = self.tmp / "fenix-selected-skills.json"
        self.md = self.tmp / "fenix-selected-skills.md"
        self.target = self.tmp / "skills"
        self.repo, self.version = self.make_repo("demo", "root", "")
        self.write_data(
            [
                {
                    "type": "测试",
                    "name": "root-skill",
                    "repo": "demo/root",
                    "path": "",
                    "version": self.version,
                    "version_kind": "commit",
                    "description": "a | b",
                    "checked_at": "",
                }
            ]
        )

    def run_git(self, *args):
        return subprocess.run(
            ["git", *map(str, args)], check=True, capture_output=True, text=True
        ).stdout.strip()

    def push_current(self, work, bare):
        branch = self.run_git("-C", work, "rev-parse", "--abbrev-ref", "HEAD")
        self.run_git("-C", work, "push", "--quiet", bare, f"HEAD:{branch}")

    def make_repo(self, owner, name, path, tags=()):
        work = self.tmp / f"work-{owner}-{name}"
        skill = work / path if path else work
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text(
            "---\nname: root-skill\ndescription: test\n---\n\n# Test\n",
            encoding="utf-8",
        )
        (skill / "payload.txt").write_text("payload\n", encoding="utf-8")
        self.run_git("init", "--quiet", work)
        self.run_git("-C", work, "config", "user.email", "test@example.com")
        self.run_git("-C", work, "config", "user.name", "Test")
        self.run_git("-C", work, "add", ".")
        self.run_git("-C", work, "commit", "--quiet", "-m", "initial")
        for tag in tags:
            self.run_git("-C", work, "tag", tag)
        bare = self.remote / owner / f"{name}.git"
        bare.parent.mkdir(parents=True, exist_ok=True)
        self.run_git("clone", "--quiet", "--bare", work, bare)
        version = self.run_git("-C", work, "rev-parse", "HEAD")
        return bare, version

    def write_data(self, skills):
        value = {"schema_version": 1, "updated_at": "2000-01-01", "notes": [], "skills": skills}
        self.data.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def read_data(self):
        return json.loads(self.data.read_text(encoding="utf-8"))

    def run_script(self, *args, env=None, expected=0):
        actual_env = dict(os.environ, HOME=str(self.tmp), NO_COLOR="1")
        if env:
            actual_env.update(env)
        proc = subprocess.run(
            ["bash", str(self.script), *map(str, args)],
            cwd=self.tmp,
            env=actual_env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60,
        )
        self.assertEqual(
            proc.returncode,
            expected,
            f"command: {args}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        return proc

    def offline_env(self, code=None):
        bindir = self.tmp / "bin"
        bindir.mkdir(exist_ok=True)
        if self.native_windows:
            curl = bindir / "curl.bat"
            curl.write_text("@echo off\r\n" + (f"echo {code}\r\n" if code else "exit /b 1\r\n"), encoding="utf-8")
            gh = bindir / "gh.bat"
            gh.write_text("@echo off\r\nexit /b 1\r\n", encoding="utf-8")
        else:
            curl = bindir / "curl"
            if code is None:
                curl.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            else:
                curl.write_text(f"#!/bin/sh\nprintf '{code}'\n", encoding="utf-8")
            curl.chmod(0o755)
            gh = bindir / "gh"
            gh.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            gh.chmod(0o755)
        return {"PATH": str(bindir) + os.pathsep + os.environ.get("PATH", "")}

    def remote_md_env(self, source):
        bindir = self.tmp / "bin-remote-md"
        bindir.mkdir(exist_ok=True)
        if self.native_windows:
            curl = bindir / "curl.bat"
            curl.write_text(
                "@echo off\r\nset \"out=\"\r\n:parse\r\n"
                "if \"%~1\"==\"\" goto done\r\n"
                "if \"%~1\"==\"-o\" (\r\n  set \"out=%~2\"\r\n  shift\r\n  shift\r\n  goto parse\r\n)\r\n"
                "shift\r\ngoto parse\r\n:done\r\n"
                "copy /y \"%FIXTURE_SKILL%\" \"%out%\" >nul\r\n",
                encoding="utf-8",
            )
            gh = bindir / "gh.bat"
            gh.write_text("@echo off\r\nexit /b 1\r\n", encoding="utf-8")
        else:
            curl = bindir / "curl"
            curl.write_text(
                "#!/bin/sh\n"
                "out=''\n"
                "while [ $# -gt 0 ]; do\n"
                "  if [ \"$1\" = '-o' ]; then out=\"$2\"; shift 2; else shift; fi\n"
                "done\n"
                "cp \"$FIXTURE_SKILL\" \"$out\"\n",
                encoding="utf-8",
            )
            curl.chmod(0o755)
            gh = bindir / "gh"
            gh.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            gh.chmod(0o755)
        env = {
            "PATH": str(bindir) + os.pathsep + os.environ.get("PATH", ""),
            "FIXTURE_SKILL": str(source),
        }
        if self.native_windows:
            script = self.script.read_text(encoding="utf-8-sig")
            boundary = "function Get-RemoteSkillMd("
            override = 'if ($env:FENIX_TEST_CURL) { $script:CurlCmd = Get-Command $env:FENIX_TEST_CURL }\n\n'
            if override not in script:
                self.script.write_text(script.replace(boundary, override + boundary, 1), encoding="utf-8-sig")
            env["FENIX_TEST_CURL"] = str(curl)
        return env

    def install(self):
        return self.run_script("install", "root-skill", "--target", self.target)

    def test_empty_root_path_and_markdown_pipe(self):
        self.run_script("check")
        listing = self.run_script("list").stdout
        self.assertIn("a \\| b", listing)
        self.install()
        self.assertTrue((self.target / "root-skill" / "SKILL.md").is_file())
        self.assertEqual(self.read_data()["skills"][0]["path"], "")

    def test_sync_dry_run_changes_nothing(self):
        before = digest(self.data)
        self.run_script("sync", "root-skill", "--dry-run", "--target", self.target)
        self.assertEqual(digest(self.data), before)
        self.assertFalse(self.md.exists())
        self.assertFalse(self.target.exists())

    def test_failed_download_preserves_managed_install(self):
        self.install()
        extra = self.target / "root-skill" / "keep.txt"
        extra.write_text("keep\n", encoding="utf-8")
        data = self.read_data()
        data["skills"][0]["path"] = "missing"
        self.write_data(data["skills"])
        self.run_script("install", "root-skill", "--force", "--target", self.target, expected=1)
        self.assertEqual(extra.read_text(encoding="utf-8"), "keep\n")
        self.assertTrue((self.target / "root-skill" / "SKILL.md").is_file())

    def test_unmanaged_sync_requires_force_and_backs_up(self):
        original = self.target / "root-skill"
        original.mkdir(parents=True)
        (original / "SKILL.md").write_text("local\n", encoding="utf-8")
        env = self.offline_env()
        proc = self.run_script("sync", "root-skill", "--target", self.target, env=env)
        self.assertIn("--force", proc.stdout + proc.stderr)
        self.assertEqual((original / "SKILL.md").read_text(encoding="utf-8"), "local\n")
        status = self.run_script("status", "--target", self.target).stdout
        self.assertIn("未托管", status)
        self.run_script("sync", "root-skill", "--force", "--target", self.target, env=env)
        self.assertIn("name: root-skill", (original / "SKILL.md").read_text(encoding="utf-8"))
        backups = list((self.target / ".backups").glob("root-skill-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "SKILL.md").read_text(encoding="utf-8"), "local\n")

    def test_update_reinstalls_missing_managed_directory(self):
        self.install()
        shutil.rmtree(self.target / "root-skill")
        self.run_script("update", "root-skill", "--target", self.target)
        self.assertTrue((self.target / "root-skill" / "SKILL.md").is_file())

    def test_semver_ignores_prefix_and_prefers_release(self):
        self.run_git("-C", self.repo, "tag", "v1.0.0-alpha.1")
        self.run_git("-C", self.repo, "tag", "v1.0.0")
        self.run_git("-C", self.repo, "tag", "v1.2.0")
        self.run_git("-C", self.repo, "tag", "skill-v4.10.0-beta.1")
        self.run_git("-C", self.repo, "tag", "skill-v4.10.0")
        self.run_script("refresh", "root-skill")
        self.assertEqual(self.read_data()["skills"][0]["version"], "skill-v4.10.0")
        self.run_git("-C", self.repo, "tag", "foo-1.0.0-v5.0.0")
        self.run_git("-C", self.repo, "tag", "v5.0.0-alpha-1+build-x")
        self.run_script("refresh", "root-skill")
        self.assertEqual(self.read_data()["skills"][0]["version"], "foo-1.0.0-v5.0.0")
        long_tag = "v999999999999999999999999.0.0"
        self.run_git("-C", self.repo, "tag", long_tag)
        self.run_script("refresh", "root-skill")
        self.assertEqual(self.read_data()["skills"][0]["version"], long_tag)

    def test_network_http_error_fails_without_success_message(self):
        proc = self.run_script("check", "--network", env=self.offline_env("404"), expected=1)
        output = proc.stdout + proc.stderr
        self.assertIn("HTTP 404", output)
        self.assertNotIn("远端检查通过", output)
        self.assertNotIn("✓ 检查通过", output)

    def test_add_missing_value_and_path_validation(self):
        proc = self.run_script("add", "--name", expected=1)
        self.assertIn("--name 需要参数", proc.stdout + proc.stderr)
        data = self.read_data()
        data["skills"][0]["path"] = "..foo"
        self.write_data(data["skills"])
        self.run_script("check")
        data["skills"][0]["path"] = "..\\escape"
        self.write_data(data["skills"])
        self.run_script("check", expected=1)

    def test_batch_continues_after_unknown_name_but_returns_failure(self):
        self.run_script("install", "unknown", "root-skill", "--target", self.target, expected=1)
        self.assertTrue((self.target / "root-skill" / "SKILL.md").is_file())

    def test_empty_version_keeps_columns_aligned(self):
        data = self.read_data()
        data["skills"][0]["version"] = ""
        data["skills"][0]["version_kind"] = "commit"  # add --no-refresh 的中间态
        self.write_data(data["skills"])

        proc = self.run_script("check", expected=1)
        output = proc.stdout + proc.stderr
        self.assertIn("version 为空", output)
        # 空字段若挤掉后面的列，会误报 version_kind 非法 / path 非法
        self.assertNotIn("version_kind 只能是", output)
        self.assertNotIn("path 必须", output)

        status = self.run_script("status", "--target", self.target).stdout
        self.assertNotIn("commit", status)

        proc = self.run_script(
            "install", "root-skill", "--target", self.target,
            env=self.offline_env(), expected=1,
        )
        self.assertIn("版本为空", proc.stdout + proc.stderr)
        self.assertFalse((self.target / "root-skill").exists())

    def test_empty_type_reported_without_shifting_columns(self):
        data = self.read_data()
        data["skills"][0]["type"] = ""
        data["skills"][0]["description"] = "第一行\n第二行"
        self.write_data(data["skills"])

        proc = self.run_script("check", expected=1)
        output = proc.stdout + proc.stderr
        self.assertIn("type 为空", output)
        self.assertNotIn("version 为空", output)
        self.assertNotIn("path 必须", output)
        self.assertNotIn("version_kind 只能是", output)

    def test_relative_state_file_lands_in_cwd(self):
        env = {"SKILLS_STATE_FILE": "state.json"}
        self.run_script("install", "root-skill", "--target", self.target, env=env)
        state = self.tmp / "state.json"
        self.assertTrue(state.is_file())
        self.assertIn("root-skill", json.loads(state.read_text(encoding="utf-8"))["skills"])

    def test_info_commands_reject_extra_args(self):
        for cmd in ("help", "env", "list", "render"):
            proc = self.run_script(cmd, "extra", expected=1)
            self.assertIn("不接受参数", proc.stdout + proc.stderr)

    def test_path_forms_are_normalized(self):
        _, version = self.make_repo("demo", "nested", "skills/x")
        for path in ("skills/x/", "./skills/x", "skills//x", "skills/x/."):
            self.write_data([
                {
                    "type": "测试",
                    "name": "nested-skill",
                    "repo": "demo/nested",
                    "path": path,
                    "version": version,
                    "version_kind": "commit",
                    "description": "",
                    "checked_at": "",
                }
            ])
            self.run_script("check")
            self.run_script("install", "nested-skill", "--target", self.target)
            self.assertTrue((self.target / "nested-skill" / "SKILL.md").is_file(), path)
            shutil.rmtree(self.target)
        self.run_script(
            "add", "--name", "added", "--type", "测试", "--repo", "demo/nested",
            "--path", "skills/x/", "--no-refresh",
        )
        self.assertEqual(self.read_data()["skills"][-1]["path"], "skills/x")

    def test_control_chars_in_path_fail_check(self):
        data = self.read_data()
        data["skills"][0]["path"] = "skills/\nx"
        self.write_data(data["skills"])
        proc = self.run_script("check", expected=1)
        self.assertIn("path 必须", proc.stdout + proc.stderr)

    def test_malformed_skills_entry_fails_all_commands(self):
        self.write_data(["oops"])
        for args in (("check",), ("status", "--target", self.target)):
            proc = self.run_script(*args, expected=1)
            self.assertIn("结构错误", proc.stdout + proc.stderr)

    def test_non_string_field_types_fail(self):
        data = self.read_data()
        data["skills"][0]["version"] = 1.5
        self.write_data(data["skills"])
        proc = self.run_script("check", expected=1)
        self.assertIn("结构错误", proc.stdout + proc.stderr)

    def test_network_unreachable_api_keeps_raw_http_error(self):
        bindir = self.tmp / "bin-raw-only"
        bindir.mkdir(exist_ok=True)
        if self.native_windows:
            curl = bindir / "curl.bat"
            curl.write_text(
                "@echo off\r\necho %*| find \"api.github.com\" >nul && exit /b 1\r\necho 404\r\n",
                encoding="utf-8",
            )
            gh = bindir / "gh.bat"
            gh.write_text("@echo off\r\nexit /b 1\r\n", encoding="utf-8")
        else:
            curl = bindir / "curl"
            curl.write_text(
                "#!/bin/sh\n"
                "case \"$*\" in\n"
                "  *api.github.com*) exit 1 ;;\n"
                "esac\n"
                "printf '404'\n",
                encoding="utf-8",
            )
            curl.chmod(0o755)
            gh = bindir / "gh"
            gh.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            gh.chmod(0o755)
        env = {"PATH": str(bindir) + os.pathsep + os.environ.get("PATH", "")}

        proc = self.run_script("check", "--network", env=env, expected=1)
        output = proc.stdout + proc.stderr
        self.assertIn("HTTP 404", output)
        self.assertNotIn("远端未验证", output)

    def test_sync_failure_returns_nonzero_and_restores_entry(self):
        data = self.read_data()
        data["skills"][0]["path"] = "missing"
        self.write_data(data["skills"])
        before = self.read_data()["skills"][0]
        proc = self.run_script("sync", "root-skill", "--target", self.target, expected=1)
        self.assertIn("缺少 SKILL.md", proc.stdout + proc.stderr)
        self.assertEqual(self.read_data()["skills"][0], before)
        self.assertFalse((self.target / "root-skill").exists())

    def test_status_compares_full_version_and_kind(self):
        skill = self.target / "root-skill"
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text("test\n", encoding="utf-8")
        marker = {
            "repo": "demo/root", "path": "", "version": "3d5508ab",
            "version_kind": "tag", "installed_at": "2026-01-01 00:00",
        }
        (skill / ".skill-manager.json").write_text(json.dumps(marker), encoding="utf-8")
        data = self.read_data()
        data["skills"][0]["version"] = "3d5508abdeadbeef"
        data["skills"][0]["version_kind"] = "commit"
        self.write_data(data["skills"])
        output = self.run_script("status", "--target", self.target).stdout
        self.assertIn("可更新", output)
        self.assertNotIn("已最新", output)

    def test_sparse_checkout_anchors_top_level_directory(self):
        _, _ = self.make_repo("demo", "anchor", "demo", tags=("v1.0.0",))
        data = self.read_data()
        data["skills"][0].update(
            repo="demo/anchor", path="demo", version="v1.0.0", version_kind="tag"
        )
        self.write_data(data["skills"])
        bindir = self.tmp / "bin-git-log"
        bindir.mkdir()
        real_git = shutil.which("git")
        log = self.tmp / "git.log"
        if self.native_windows:
            wrapper = bindir / "git.bat"
            wrapper.write_text(
                "@echo off\r\n>>\"%GIT_LOG%\" echo %*\r\n"
                "\"%REAL_GIT%\" %*\r\nexit /b %errorlevel%\r\n",
                encoding="utf-8",
            )
        else:
            wrapper = bindir / "git"
            wrapper.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$GIT_LOG\"\n"
                "exec \"$REAL_GIT\" \"$@\"\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
        env = {
            "PATH": str(bindir) + os.pathsep + os.environ["PATH"],
            "GIT_LOG": str(log), "REAL_GIT": str(real_git),
        }
        self.run_script("install", "root-skill", "--target", self.target, env=env)
        self.assertIn("sparse-checkout set --no-cone /demo/", log.read_text(encoding="utf-8"))
        self.assertTrue((self.target / "root-skill" / "SKILL.md").is_file())

    def test_sync_dry_run_adoption_is_explicit_and_writes_nothing(self):
        source = self.tmp / "work-demo-root" / "SKILL.md"
        skill = self.target / "root-skill"
        skill.mkdir(parents=True)
        shutil.copyfile(source, skill / "SKILL.md")
        before = digest(self.data)
        proc = self.run_script(
            "sync", "root-skill", "--dry-run", "--target", self.target,
            env=self.remote_md_env(source),
        )
        self.assertIn("[dry-run] root-skill：内容与最新版一致，将纳入管理", proc.stdout)
        self.assertEqual(digest(self.data), before)
        self.assertFalse((skill / ".skill-manager.json").exists())
        self.assertFalse((self.target / ".skills-manager.json").exists())

    def test_bom_frontmatter_name_is_checked(self):
        skill = self.target / "root-skill"
        skill.mkdir(parents=True)
        content = "---\nname: other\ndescription: test\n---\n"
        (skill / "SKILL.md").write_bytes(b"\xef\xbb\xbf" + content.encode("utf-8"))
        proc = self.run_script(
            "sync", "root-skill", "--dry-run", "--target", self.target,
            env=self.offline_env(),
        )
        self.assertIn("不一致", proc.stdout + proc.stderr)

    def test_non_directory_sync_message_is_not_contradictory(self):
        self.target.mkdir(parents=True)
        (self.target / "root-skill").write_text("file\n", encoding="utf-8")
        proc = self.run_script("sync", "root-skill", "--dry-run", "--target", self.target)
        output = proc.stdout + proc.stderr
        self.assertIn("不是目录", output)
        self.assertNotIn("[dry-run] root-skill：将安装", output)

    def test_copy_failure_preserves_old_install_and_restores_sync_entry(self):
        if self.implementation != "bash":
            self.skipTest("仅注入 Bash cp 失败")
        bare, _ = self.make_repo("demo", "copy", "skills/x", tags=("v1.0.0",))
        data = self.read_data()
        data["skills"][0].update(repo="demo/copy", path="skills/x", version="v1.0.0", version_kind="tag")
        self.write_data(data["skills"])
        self.install()
        skill_md = self.target / "root-skill" / "SKILL.md"
        before_content = skill_md.read_bytes()
        before_entry = self.read_data()["skills"][0]
        self.run_git("-C", bare, "tag", "v2.0.0")
        bindir = self.tmp / "bin-cp-fail"
        bindir.mkdir()
        cp = bindir / "cp"
        cp.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        cp.chmod(0o755)
        env = {"PATH": str(bindir) + os.pathsep + os.environ["PATH"]}
        self.run_script("install", "root-skill", "--force", "--target", self.target, env=env, expected=1)
        self.assertEqual(skill_md.read_bytes(), before_content)
        self.run_script("sync", "root-skill", "--target", self.target, env=env, expected=1)
        self.assertEqual(skill_md.read_bytes(), before_content)
        self.assertEqual(self.read_data()["skills"][0], before_entry)

    def test_tar_failure_preserves_old_install(self):
        if self.implementation != "bash":
            self.skipTest("仅注入 Bash tar 失败")
        self.install()
        skill_md = self.target / "root-skill" / "SKILL.md"
        before = skill_md.read_bytes()
        bindir = self.tmp / "bin-tar-fail"
        bindir.mkdir()
        tar = bindir / "tar"
        tar.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        tar.chmod(0o755)
        env = {"PATH": str(bindir) + os.pathsep + os.environ["PATH"]}
        self.run_script("install", "root-skill", "--force", "--target", self.target, env=env, expected=1)
        self.assertEqual(skill_md.read_bytes(), before)

    def test_update_failure_returns_nonzero_and_restores_entry(self):
        bare, _ = self.make_repo("demo", "update", "skills/x", tags=("v1.0.0",))
        data = self.read_data()
        data["skills"][0].update(repo="demo/update", path="skills/x", version="v1.0.0", version_kind="tag")
        self.write_data(data["skills"])
        self.install()
        self.run_git("-C", bare, "tag", "v2.0.0")
        data = self.read_data()
        data["skills"][0]["path"] = "missing"
        self.write_data(data["skills"])
        before = self.read_data()["skills"][0]
        self.run_script("update", "root-skill", "--target", self.target, expected=1)
        self.assertEqual(self.read_data()["skills"][0], before)
        marker = json.loads((self.target / "root-skill" / ".skill-manager.json").read_text(encoding="utf-8"))
        self.assertEqual(marker["version"], "v1.0.0")

    def test_marker_write_failure_restores_update_and_sync_entries(self):
        # BUG-030：暂存标记写入抛异常时，sync/update 也必须回滚名单版本。
        bare, _ = self.make_repo("demo", "marker", "skills/x", tags=("v1.0.0",))
        data = self.read_data()
        data["skills"][0].update(repo="demo/marker", path="skills/x", version="v1.0.0", version_kind="tag")
        self.write_data(data["skills"])
        self.install()
        skill_md = self.target / "root-skill" / "SKILL.md"
        before_md = skill_md.read_bytes()
        before_entry = self.read_data()["skills"][0]
        work = self.tmp / "work-demo-marker"
        marker_dir = work / "skills" / "x" / ".skill-manager.json"
        marker_dir.mkdir(parents=True)
        (marker_dir / "blocked.txt").write_text("x\n", encoding="utf-8")
        self.run_git("-C", work, "add", "-A")
        self.run_git("-C", work, "commit", "--quiet", "-m", "marker dir")
        self.push_current(work, bare)
        self.run_git("-C", bare, "tag", "v2.0.0")

        self.run_script("update", "root-skill", "--target", self.target, expected=1)
        self.assertEqual(self.read_data()["skills"][0], before_entry)
        self.assertEqual(skill_md.read_bytes(), before_md)

        self.run_script("sync", "root-skill", "--target", self.target, expected=1)
        self.assertEqual(self.read_data()["skills"][0], before_entry)
        self.assertEqual(skill_md.read_bytes(), before_md)
        marker = json.loads((self.target / "root-skill" / ".skill-manager.json").read_text(encoding="utf-8"))
        self.assertEqual(marker["version"], "v1.0.0")

    def test_sync_duplicate_name_failure_restores_entry(self):
        # BUG-036：同名重复传入时，回滚快照不能用第二遍升级后的版本。
        bare, _ = self.make_repo("demo", "dup", "skills/x", tags=("v1.0.0",))
        data = self.read_data()
        data["skills"][0].update(repo="demo/dup", path="skills/x", version="v1.0.0", version_kind="tag")
        self.write_data(data["skills"])
        self.install()
        self.run_git("-C", bare, "tag", "v2.0.0")
        data = self.read_data()
        data["skills"][0]["path"] = "missing"
        self.write_data(data["skills"])
        before = self.read_data()["skills"][0]
        self.run_script("sync", "root-skill", "root-skill", "--target", self.target, expected=1)
        self.assertEqual(self.read_data()["skills"][0], before)

    def test_sync_repairs_skill_md_directory(self):
        # BUG-037：历史安装里 SKILL.md 是目录时，sync 应重装修复而不是抛异常退出。
        self.install()
        skill_md = self.target / "root-skill" / "SKILL.md"
        skill_md.unlink()
        skill_md.mkdir()
        (skill_md / "junk.txt").write_text("junk\n", encoding="utf-8")
        self.run_script("sync", "root-skill", "--target", self.target)
        self.assertTrue(skill_md.is_file())
        self.assertIn("name: root-skill", skill_md.read_text(encoding="utf-8"))

    def fail_install_moves(self, *names):
        env = {}
        if self.implementation == "bash":
            bindir = self.tmp / "bin-failed-move"
            bindir.mkdir()
            stub = bindir / "mv"
            stub.write_text(
                '#!/bin/sh\ncase "$1" in ' + "|".join(f"*/{name}" for name in names)
                + ') exit 1;; esac\nexec /bin/mv "$@"\n',
                encoding="utf-8",
            )
            stub.chmod(0o755)
            env["PATH"] = str(bindir) + os.pathsep + os.environ["PATH"]
        else:
            script = self.script.read_text(encoding="utf-8-sig")
            patterns = ",".join(f"'{name}'" for name in names)
            self.script.write_text(
                "function Move-Item {\n"
                "  param([string]$LiteralPath, [string]$Destination)\n"
                f"  if ([IO.Path]::GetFileName($LiteralPath) -in @({patterns})) {{ throw 'move failed' }}\n"
                "  Microsoft.PowerShell.Management\\Move-Item -LiteralPath $LiteralPath -Destination $Destination\n"
                "}\n" + script,
                encoding="utf-8-sig",
            )
        return env

    def assert_failed_rollback_preserves_old_directory(self, fail_replacement):
        self.install()
        target = self.target / "root-skill"
        before = {path.name: path.read_bytes() for path in target.iterdir()}
        original = self.read_data()["skills"][0]
        self.run_git("-C", self.repo, "tag", "v2.0.0")
        env = self.fail_install_moves("staged", "old") if fail_replacement else self.fail_install_moves("old")
        if not fail_replacement:
            blocked = self.tmp / "blocked-state"
            blocked.mkdir()
            env["SKILLS_STATE_FILE"] = str(blocked)
        result = self.run_script("sync", "root-skill", "--target", self.target, env=env, expected=1)
        self.assertFalse(target.exists())
        if not fail_replacement:
            self.assertIn("状态写入失败", result.stdout + result.stderr)
        backups = list(self.target.glob(".install-root-skill*/old"))
        self.assertEqual(len(backups), 1, result.stdout + result.stderr)
        self.assertEqual({path.name: path.read_bytes() for path in backups[0].iterdir()}, before)
        self.assertIn(str(backups[0]), result.stdout + result.stderr)
        self.assertEqual(self.read_data()["skills"][0], original)

    def test_failed_install_and_rollback_preserves_old_directory(self):
        self.assert_failed_rollback_preserves_old_directory(fail_replacement=True)

    def test_failed_state_write_and_rollback_preserves_old_directory(self):
        self.assert_failed_rollback_preserves_old_directory(fail_replacement=False)

    def test_adoption_marker_failure_leaves_existing_state_unchanged(self):
        source = self.tmp / "work-demo-root" / "SKILL.md"
        target = self.target / "root-skill"
        marker = target / ".skill-manager.json"
        marker.mkdir(parents=True)
        (marker / "keep").write_bytes(b"keep")
        shutil.copyfile(source, target / "SKILL.md")
        state = self.target / ".skills-manager.json"
        before_state = b'{"skills":{"other":{"version":"v1.0.0"}}}\n'
        state.write_bytes(before_state)
        original = self.read_data()["skills"][0]
        self.run_git("-C", self.repo, "tag", "v2.0.0")
        result = self.run_script(
            "sync", "root-skill", "--target", self.target, env=self.remote_md_env(source), expected=1,
        )
        self.assertNotIn("纳入管理", result.stdout)
        self.assertEqual(state.read_bytes(), before_state)
        self.assertEqual(self.read_data()["skills"][0], original)
        self.assertEqual((marker / "keep").read_bytes(), b"keep")

    def test_adoption_state_failure_removes_new_marker_and_can_retry(self):
        source = self.tmp / "work-demo-root" / "SKILL.md"
        target = self.target / "root-skill"
        target.mkdir(parents=True)
        shutil.copyfile(source, target / "SKILL.md")
        state = self.target / ".skills-manager.json"
        state.mkdir()
        (state / "keep").write_bytes(b"keep")
        original = self.read_data()["skills"][0]
        self.run_git("-C", self.repo, "tag", "v2.0.0")
        env = self.remote_md_env(source)
        result = self.run_script("sync", "root-skill", "--target", self.target, env=env, expected=1)
        marker = target / ".skill-manager.json"
        self.assertNotIn("纳入管理", result.stdout)
        self.assertFalse(marker.exists())
        self.assertEqual(list(state.iterdir()), [state / "keep"])
        self.assertEqual(self.read_data()["skills"][0], original)
        shutil.rmtree(state)
        self.run_script("sync", "root-skill", "--target", self.target, env=env)
        self.assertEqual(json.loads(marker.read_text(encoding="utf-8"))["version"], "v2.0.0")
        self.assertEqual(json.loads(state.read_text(encoding="utf-8"))["skills"]["root-skill"]["version"], "v2.0.0")

    def test_leftover_adoption_marker_does_not_authorize_overwrite(self):
        source = self.tmp / "work-demo-root" / "SKILL.md"
        target = self.target / "root-skill"
        target.mkdir(parents=True)
        shutil.copyfile(source, target / "SKILL.md")
        local_file = target / "local.txt"
        local_file.write_bytes(b"local")
        state = self.target / ".skills-manager.json"
        state.mkdir()
        marker = target / ".skill-manager.json"
        env = self.remote_md_env(source)
        if self.implementation == "bash":
            stub = Path(env["PATH"].split(os.pathsep)[0]) / "rm"
            stub.write_text(
                '#!/bin/sh\ncase "$*" in */.skill-manager.json) exit 1;; esac\nexec /bin/rm "$@"\n',
                encoding="utf-8",
            )
            stub.chmod(0o755)
        else:
            script = self.script.read_text(encoding="utf-8-sig")
            self.script.write_text(
                "function Remove-Item {\n"
                "  [CmdletBinding()] param([string]$LiteralPath, [switch]$Force, [switch]$Recurse)\n"
                "  if ([IO.Path]::GetFileName($LiteralPath) -eq '.skill-manager.json') { throw 'remove failed' }\n"
                "  Microsoft.PowerShell.Management\\Remove-Item @PSBoundParameters\n"
                "}\n" + script,
                encoding="utf-8-sig",
            )
        result = self.run_script("sync", "root-skill", "--target", self.target, env=env, expected=1)
        self.assertTrue(marker.is_file(), result.stdout + result.stderr)
        state.rmdir()
        self.run_git("-C", self.repo, "tag", "v2.0.0")
        changed_source = self.tmp / "different-SKILL.md"
        changed_source.write_text("different remote content\n", encoding="utf-8")
        self.run_script(
            "sync", "root-skill", "--target", self.target,
            env=dict(env, FIXTURE_SKILL=str(changed_source)),
        )
        self.assertTrue(local_file.is_file(), "半写的收编标记不能授权覆盖本地文件")
        self.assertEqual(local_file.read_bytes(), b"local")
        self.assertFalse(state.exists())
        self.run_script("sync", "root-skill", "--target", self.target, env=env)
        self.assertEqual(local_file.read_bytes(), b"local")
        self.assertEqual(json.loads(state.read_text(encoding="utf-8"))["skills"]["root-skill"]["version"], "v2.0.0")

    def test_branch_with_same_name_does_not_shadow_tag(self):
        bare, _ = self.make_repo("demo", "ambiguous", "", tags=("v1.0.0",))
        work = self.tmp / "work-demo-ambiguous"
        (work / "payload.txt").write_text("branch-content\n", encoding="utf-8")
        self.run_git("-C", work, "add", ".")
        self.run_git("-C", work, "commit", "--quiet", "-m", "branch content")
        self.run_git("-C", work, "branch", "v1.0.0")
        self.run_git("-C", work, "push", "--quiet", bare, "refs/heads/v1.0.0")
        data = self.read_data()
        data["skills"][0].update(repo="demo/ambiguous", path="", version="v1.0.0", version_kind="tag")
        self.write_data(data["skills"])
        self.install()
        self.assertEqual((self.target / "root-skill" / "payload.txt").read_text(encoding="utf-8"), "payload\n")
        marker = json.loads((self.target / "root-skill" / ".skill-manager.json").read_text(encoding="utf-8"))
        self.assertEqual(marker["version_kind"], "tag")

    def test_source_path_change_reinstalls_in_sync_and_update(self):
        bare, _ = self.make_repo("demo", "source", "first")
        work = self.tmp / "work-demo-source"
        second = work / "second"
        second.mkdir()
        (second / "SKILL.md").write_text("---\nname: root-skill\n---\nsecond\n", encoding="utf-8")
        (second / "payload.txt").write_text("second\n", encoding="utf-8")
        self.run_git("-C", work, "add", ".")
        self.run_git("-C", work, "commit", "--quiet", "-m", "second source")
        self.push_current(work, bare)
        version = self.run_git("-C", work, "rev-parse", "HEAD")
        data = self.read_data()
        data["skills"][0].update(repo="demo/source", path="first", version=version, version_kind="commit")
        self.write_data(data["skills"])
        self.install()
        data["skills"][0]["path"] = "second"
        self.write_data(data["skills"])
        self.run_script("sync", "root-skill", "--target", self.target)
        self.assertEqual((self.target / "root-skill" / "payload.txt").read_text(encoding="utf-8"), "second\n")
        data["skills"][0]["path"] = "first"
        self.write_data(data["skills"])
        self.run_script("update", "root-skill", "--target", self.target)
        self.assertEqual((self.target / "root-skill" / "payload.txt").read_text(encoding="utf-8"), "payload\n")

    def test_skill_md_directory_is_rejected(self):
        bare, _ = self.make_repo("demo", "dir-entry", "")
        work = self.tmp / "work-demo-dir-entry"
        (work / "SKILL.md").unlink()
        (work / "SKILL.md").mkdir()
        (work / "SKILL.md" / "data.txt").write_text("not an entry\n", encoding="utf-8")
        self.run_git("-C", work, "add", "-A")
        self.run_git("-C", work, "commit", "--quiet", "-m", "directory entry")
        self.push_current(work, bare)
        version = self.run_git("-C", work, "rev-parse", "HEAD")
        data = self.read_data()
        data["skills"][0].update(repo="demo/dir-entry", version=version)
        self.write_data(data["skills"])
        self.run_script("install", "root-skill", "--target", self.target, expected=1)
        self.assertFalse((self.target / "root-skill").exists())


@unittest.skipUnless(
    os.environ.get("FENIX_TEST_DOCKER_BASH") == "1",
    "设置 FENIX_TEST_DOCKER_BASH=1 后在 Docker Bash 5 中运行同一组场景"
    "（镜像缺失时按 tests/Dockerfile.bash 自动构建）",
)
class DockerBashSkillsScriptTest(SkillsScriptTest):
    @classmethod
    def setUpClass(cls):
        custom = os.environ.get("FENIX_BASH_IMAGE")
        cls.image = ensure_docker_image(
            custom or DEFAULT_BASH_IMAGE, "Dockerfile.bash", auto_build=not custom
        )
        cls.git_path = docker_git_path(cls.image)

    def run_script(self, *args, env=None, expected=0):
        command = [
            "docker", "run", "--rm", "--network", "none",
            "-e", f"HOME={self.tmp}", "-w", str(self.tmp),
            "-v", f"{self.tmp}:{self.tmp}",
        ]
        for key, value in (env or {}).items():
            if key == "PATH":
                stub = value.split(os.pathsep)[0]
                command += ["-e", f"PATH={stub}:/usr/local/bin:/usr/bin:/bin"]
            elif key == "REAL_GIT":
                command += ["-e", f"REAL_GIT={self.git_path}"]
            else:
                command += ["-e", f"{key}={value}"]
        command += [self.image, "bash", str(self.script)]
        command += list(map(str, args))
        proc = subprocess.run(
            command,
            cwd=self.tmp,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
        self.assertEqual(
            proc.returncode,
            expected,
            f"command: {args}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        return proc


@unittest.skipUnless(
    os.environ.get("FENIX_TEST_DOCKER_PWSH") == "1",
    "设置 FENIX_TEST_DOCKER_PWSH=1 后在 Docker PowerShell 中运行同一组场景"
    "（镜像缺失时按 tests/Dockerfile.pwsh 自动构建）",
)
class PowerShellSkillsScriptTest(SkillsScriptTest):
    implementation = "powershell"
    @classmethod
    def setUpClass(cls):
        custom = os.environ.get("FENIX_PWSH_IMAGE")
        cls.image = ensure_docker_image(
            custom or DEFAULT_PWSH_IMAGE, "Dockerfile.pwsh", auto_build=not custom
        )
        cls.git_path = docker_git_path(cls.image)

    def setUp(self):
        super().setUp()
        source = SOURCE.with_suffix(".ps1").read_text(encoding="utf-8-sig")
        source = source.replace("$GitHub = 'https://github.com'", f"$GitHub = '{self.remote}'")
        self.script = self.tmp / "fenix-selected-skills.ps1"
        self.script.write_text(source, encoding="utf-8")

    def run_script(self, *args, env=None, expected=0):
        command = [
            "docker", "run", "--rm", "--network", "none",
            "-e", "OS=Windows_NT", "-e", f"HOME={self.tmp}",
            "-w", str(self.tmp), "-v", f"{self.tmp}:{self.tmp}",
        ]
        for key, value in (env or {}).items():
            if key == "PATH":
                stub = value.split(os.pathsep)[0]
                command += ["-e", f"PATH={stub}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
            elif key == "REAL_GIT":
                command += ["-e", f"REAL_GIT={self.git_path}"]
            else:
                command += ["-e", f"{key}={value}"]
        command += [self.image, "pwsh", "-NoProfile", "-File", str(self.script)]
        command += list(map(str, args))
        proc = subprocess.run(
            command,
            cwd=self.tmp,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
        self.assertEqual(
            proc.returncode,
            expected,
            f"command: {args}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        return proc


@unittest.skipUnless(
    os.name == "nt" and (shutil.which("pwsh") or shutil.which("powershell")),
    "仅在 Windows 本机 PowerShell 中运行",
)
class NativeWindowsPowerShellSkillsScriptTest(SkillsScriptTest):
    native_windows = True
    implementation = "powershell"

    @classmethod
    def setUpClass(cls):
        cls.executable = shutil.which("pwsh") or shutil.which("powershell")

    def setUp(self):
        super().setUp()
        source = SOURCE.with_suffix(".ps1").read_text(encoding="utf-8-sig")
        source = source.replace("$GitHub = 'https://github.com'", f"$GitHub = '{self.remote}'")
        self.script = self.tmp / "fenix-selected-skills.ps1"
        self.script.write_text(source, encoding="utf-8")

    def run_script(self, *args, env=None, expected=0):
        actual_env = dict(os.environ, HOME=str(self.tmp), NO_COLOR="1")
        actual_env.update(env or {})
        proc = subprocess.run(
            [
                self.executable, "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(self.script), *map(str, args),
            ],
            cwd=self.tmp,
            env=actual_env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
        self.assertEqual(
            proc.returncode,
            expected,
            f"command: {args}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        return proc


if __name__ == "__main__":
    unittest.main()
