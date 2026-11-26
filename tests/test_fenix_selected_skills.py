"""fenix-selected-skills.sh / .ps1 的本地端到端回归测试。

默认只跑本机 Bash；跨环境回归按需开启：

    FENIX_TEST_DOCKER_BASH=1  # Docker Bash 5（默认镜像 fenix-selected-skills-bash:test）
    FENIX_TEST_DOCKER_PWSH=1  # Docker PowerShell 7.4（默认镜像 fenix-selected-skills-pwsh:test）

两种 Docker 镜像缺少依赖时，测试会用 tests/Dockerfile.bash / tests/Dockerfile.pwsh
自动构建一次；构建失败（例如离线）时整组跳过并给出原因。也可用
FENIX_BASH_IMAGE / FENIX_PWSH_IMAGE 指定已构建好的镜像。
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


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class SkillsScriptTest(unittest.TestCase):
    def setUp(self):
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
    @classmethod
    def setUpClass(cls):
        custom = os.environ.get("FENIX_PWSH_IMAGE")
        cls.image = ensure_docker_image(
            custom or DEFAULT_PWSH_IMAGE, "Dockerfile.pwsh", auto_build=not custom
        )

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


if __name__ == "__main__":
    unittest.main()
