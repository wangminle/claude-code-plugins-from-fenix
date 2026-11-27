#!/usr/bin/env bash
# fenix-selected-skills.sh — 自选 Claude Skills 名单的安装 / 更新工具
#
# 用法：./fenix-selected-skills.sh <命令> [参数...]
#   list                     打印名单表格
#   render                   重新生成 fenix-selected-skills.md
#   refresh [名称...]         查询 GitHub 最新版本并写回 fenix-selected-skills.json（默认全部）
#   sync [名称...] [--dry-run] [--force] [--target user|project|目录]
#                            对齐安装：缺失则安装最新版；已存在则校验名称与版本，
#                            过旧则更新（默认全部；默认用户级）
#   install [名称...] [--force] [--target ...]
#                            按名单当前版本安装；默认跳过非托管同名目录
#   update [名称...] [--target ...]
#                            已安装技能有新版则重装（默认所有已安装项）
#   status [--target ...]    查看安装状态与名单记录版本（不联网）
#   env                      打印平台、依赖与目标目录
#   check [--network]        校验 fenix-selected-skills.json（--network 额外验证仓库路径可访问）
#   add --name N --type T --repo O/R [--path P] [--desc D] [--no-refresh]
#                            追加条目并刷新版本
#   remove <名称>             从名单移除（不删除已安装目录）
#   help                     显示本帮助
#
# 依赖：bash、git、jq；check --network 另需 curl。
# 下载策略：安装只拉取 skills[].path 指向的子目录（git blobless + sparse checkout），
#           不下载整个仓库；仅当 path 为仓库根目录时才整仓浅克隆。
# 安装目录：--target user（默认，~/.claude/skills）、project（当前目录/.claude/skills）
#           或任意目录；环境变量 CLAUDE_SKILLS_DIR 可覆盖 user。
# 状态文件：$SKILLS_DIR/.skills-manager.json（每目标一份；SKILLS_STATE_FILE 可覆盖）
# 版本口径：仓库有语义化 tag 取最新 tag，否则取默认分支 HEAD 提交 SHA。

set -euo pipefail
# macOS Bash 3.2 在不支持的 C.UTF-8 locale 下会把中文标点误并入变量名。
export LC_ALL=C
# 仓库私有或不存在时禁止 git 在终端等待账号密码（脚本场景直接失败而不是卡住）。
export GIT_TERMINAL_PROMPT=0

# 字段分隔符：Bash 的 read 只会折叠空白类 IFS 字符，
# 用 \x1f（单元分隔符）拼接字段可保证空字段不会被后面的值挤掉。
IFS_SEP=$'\x1f'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_FILE="$SCRIPT_DIR/fenix-selected-skills.json"
MD_FILE="$SCRIPT_DIR/fenix-selected-skills.md"
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
STATE_FILE="${SKILLS_STATE_FILE:-$SKILLS_DIR/.skills-manager.json}"
GITHUB="https://github.com"
TYPE_ORDER='["文档处理","内容抓取","内容创作","前端开发","开发流程","工程工具","项目管理","浏览器自动化","辅助增强"]'

# 环境探测：Git Bash / MSYS / Cygwin 下切到 PowerShell 版
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    ps_cmd=""
    if command -v pwsh.exe >/dev/null 2>&1; then
      ps_cmd="pwsh.exe"
    elif command -v powershell.exe >/dev/null 2>&1; then
      ps_cmd="powershell.exe"
    fi
    if [ -n "$ps_cmd" ] && [ -f "$SCRIPT_DIR/fenix-selected-skills.ps1" ]; then
      ps_script="$SCRIPT_DIR/fenix-selected-skills.ps1"
      if command -v cygpath >/dev/null 2>&1; then
        ps_script="$(cygpath -w "$ps_script")"
      fi
      exec "$ps_cmd" -NoProfile -ExecutionPolicy Bypass -File "$ps_script" "$@"
    fi
    ;;
esac

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi

TMP_ROOT=""
TMP_FILE=""
VER_CACHE=""
cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
  if [ -n "$TMP_FILE" ] && [ -f "$TMP_FILE" ]; then
    rm -f "$TMP_FILE"
  fi
  if [ -n "$VER_CACHE" ] && [ -f "$VER_CACHE" ]; then
    rm -f "$VER_CACHE"
  fi
}
trap cleanup EXIT INT TERM

info() { printf '%s\n' "${C_B}· $*${C_0}"; }
ok()   { printf '%s\n' "${C_G}✓ $*${C_0}"; }
warn() { printf '%s\n' "${C_Y}! $*${C_0}" >&2; }
err()  { printf '%s\n' "${C_R}✗ $*${C_0}" >&2; }
die()  { err "$*"; exit 1; }

pkg_hint() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) printf 'brew install %s' "$1" ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        printf 'sudo apt-get install -y %s' "$1"
      elif command -v dnf >/dev/null 2>&1; then
        printf 'sudo dnf install -y %s' "$1"
      elif command -v apk >/dev/null 2>&1; then
        printf 'sudo apk add %s' "$1"
      else
        printf '用系统包管理器安装 %s' "$1"
      fi
      ;;
    *) printf '安装 %s' "$1" ;;
  esac
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "缺少依赖 jq（$(pkg_hint jq)）"
}
need_git() {
  command -v git >/dev/null 2>&1 || die "缺少依赖 git（$(pkg_hint git)）"
}
need_curl() {
  command -v curl >/dev/null 2>&1 || die "缺少依赖 curl（$(pkg_hint curl)）"
}
require_data() {
  [ -f "$DATA_FILE" ] || die "找不到名单文件：$DATA_FILE"
  # 结构不对（非 JSON、skills 不是对象数组、字段不是字符串）时让所有命令一致地报错，
  # 避免 jq 在循环里静默失败被当成「检查通过」，或数字版本被静默当成字符串。
  jq -e '
    def s: type == "string" or type == "null";
    (.skills | type) == "array"
    and all(.skills[];
      type == "object"
      and (.name | s) and (.type | s) and (.repo | s) and (.path | s)
      and (.version | s) and (.version_kind | s) and (.description | s))
  ' "$DATA_FILE" >/dev/null 2>&1 \
    || die "名单文件结构错误：$DATA_FILE（skills 必须是对象数组，字段必须是字符串）"
}

retry_output() {
  # retry_output <次数> <命令...>：成功时输出 stdout，失败返回 1
  local attempts="$1" n=1 out
  shift
  while [ "$n" -le "$attempts" ]; do
    if out="$("$@" 2>/dev/null)"; then
      printf '%s\n' "$out"
      return 0
    fi
    if [ "$n" -lt "$attempts" ]; then sleep 2; fi
    n=$((n + 1))
  done
  return 1
}

retry_git() {
  # retry_git <次数> <命令...>：失败时重试，最终失败才输出错误
  local attempts="$1" n=1 out
  shift
  while [ "$n" -le "$attempts" ]; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    if [ "$n" -lt "$attempts" ]; then
      warn "网络操作失败，重试 ${n}/${attempts}"
      sleep 2
    fi
    n=$((n + 1))
  done
  printf '%s\n' "$out" >&2
  return 1
}

retry_clone() {
  # retry_clone <dest> <git clone 参数...>：每次重试前清空目标目录
  local dest="$1" attempts=3 n=1 out
  shift
  while [ "$n" -le "$attempts" ]; do
    rm -rf "$dest"
    if out="$("$@" "$dest" 2>&1)"; then
      return 0
    fi
    if [ "$n" -lt "$attempts" ]; then
      warn "网络操作失败，重试 ${n}/${attempts}"
      sleep 2
    fi
    n=$((n + 1))
  done
  printf '%s\n' "$out" >&2
  return 1
}

count_skills() {
  jq '.skills | length' "$DATA_FILE"
}

fmt_ver() {
  # fmt_ver <version_kind> <version>
  if [ "$1" = "commit" ]; then
    printf '%s' "${2:0:8}"
  else
    printf '%s' "$2"
  fi
}

apply_target_arg() {
  # apply_target_arg user|project|<目录>
  local t="${1:-}"
  [ -n "$t" ] || die "--target 需要 user、project 或目录"
  case "$t" in
    user) SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" ;;
    project) SKILLS_DIR="$PWD/.claude/skills" ;;
    *) SKILLS_DIR="$t" ;;
  esac
  STATE_FILE="${SKILLS_STATE_FILE:-$SKILLS_DIR/.skills-manager.json}"
}

valid_skill_path() {
  local path="$1"
  [ -z "$path" ] && return 0
  case "$path" in
    /*|..|../*|*/../*|*/..) return 1 ;;
    *$'\n'*|*$'\r'*|*$'\x1f'*) return 1 ;;
  esac
  [[ "$path" != *'\'* ]] && ! [[ "$path" =~ ^[A-Za-z]: ]]
}

normalize_skill_path() {
  # 兼容手写/命令行传入的路径写法：去掉开头的 ./、结尾的 /、重复的 / 和内部的 /.
  # 绝对路径与 .. 原样返回，交给 valid_skill_path 判非法。
  local p="$1"
  case "$p" in
    /*) printf '%s' "$p"; return 0 ;;
  esac
  while :; do
    case "$p" in
      *//*) p="${p%%//*}/${p#*//}" ;;
      ./*) p="${p#./}" ;;
      */./*) p="${p%%/./*}/${p#*/./*}" ;;
      */) p="${p%/}" ;;
      */.) p="${p%/.}" ;;
      *) break ;;
    esac
  done
  [ -n "$p" ] || p="."
  printf '%s' "$p"
}

is_managed() {
  local name="$1"
  if [ -f "$STATE_FILE" ] && jq -e --arg n "$name" '.skills[$n] != null' "$STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi
  has_install_marker "$name"
}

has_install_marker() {
  local marker="$SKILLS_DIR/$1/.skill-manager.json"
  [ -f "$marker" ] && jq -e 'type == "object" and .adoption_pending != true' "$marker" >/dev/null 2>&1
}

installed_version() {
  # 输出 "kind<US>version"（US = \x1f）；目录不存在、未安装或无法判定时返回 1
  local name="$1"
  [ -d "$SKILLS_DIR/$name" ] || return 1
  if [ -f "$STATE_FILE" ] && jq -e --arg n "$name" '.skills[$n] != null' "$STATE_FILE" >/dev/null 2>&1; then
    jq -r --arg n "$name" '.skills[$n]
      | [(.version_kind // ""), (.version // "")] | join("\u001f")' "$STATE_FILE"
    return 0
  fi
  if has_install_marker "$name"; then
    jq -r '[(.version_kind // ""), (.version // "")] | join("\u001f")' \
      "$SKILLS_DIR/$name/.skill-manager.json" 2>/dev/null || return 1
    return 0
  fi
  return 1
}

installed_source() {
  local name="$1"
  [ -d "$SKILLS_DIR/$name" ] || return 1
  if [ -f "$STATE_FILE" ] && jq -e --arg n "$name" '.skills[$n] != null' "$STATE_FILE" >/dev/null 2>&1; then
    jq -r --arg n "$name" '.skills[$n]
      | [(.repo // ""), (.path // "")] | map(tostring) | join("\u001f")' "$STATE_FILE"
    return 0
  fi
  if has_install_marker "$name"; then
    jq -r '[(.repo // ""), (.path // "")] | map(tostring) | join("\u001f")' \
      "$SKILLS_DIR/$name/.skill-manager.json" 2>/dev/null || return 1
    return 0
  fi
  return 1
}

read_skill_name() {
  # 只读取文件首部 YAML frontmatter 中的 name，并去掉引号与首尾空白
  [ -f "$1" ] || return 0
  awk '
    NR == 1 {
      bom = sprintf("\357\273\277")
      if (substr($0, 1, 3) == bom) $0 = substr($0, 4)
      if ($0 != "---" && $0 != "---\r") exit
      next
    }
    NR > 40 || /^---\r?$/ { exit }
    /^name:/ {
      value = $0
      sub(/^name:[ \t]*/, "", value)
      gsub(/^[ \t]+|[ \t\r]+$/, "", value)
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if (length(value) >= 2 && ((first == "\"" && last == "\"") || (first == "\047" && last == "\047"))) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$1"
}

start_cache() {
  if [ -z "$VER_CACHE" ]; then
    VER_CACHE="$(mktemp "${TMPDIR:-/tmp}/skills-ver.XXXXXX")"
  fi
}

resolve_version_cached() {
  # 同 resolve_version，但同一仓库只查询一次
  local repo="$1" hit
  if [ -n "$VER_CACHE" ] && [ -f "$VER_CACHE" ]; then
    hit="$(awk -F'\t' -v r="$repo" '$1 == r { print $2 "\t" $3; exit }' "$VER_CACHE")"
    if [ -n "$hit" ]; then
      printf '%s\n' "$hit"
      return 0
    fi
  fi
  hit="$(resolve_version "$repo")" || return 1
  if [ -n "$VER_CACHE" ]; then
    printf '%s\t%s\n' "$repo" "$hit" >> "$VER_CACHE"
  fi
  printf '%s\n' "$hit"
}

render_table() {
  jq -r --arg host "$GITHUB" --argjson order "$TYPE_ORDER" '
    def cell: tostring | gsub("\r\n|\r|\n"; " ") | gsub("\\|"; "\\|");
    def normpath: (. // "") | gsub("^(\\./)+"; "") | gsub("/+$"; "")
      | gsub("/{2,}"; "/") | gsub("/\\./"; "/") | gsub("/\\.$"; "")
      | if . == "" then "." else . end;
    def pathcell: normpath | if . == "." then "—" else cell end;
    (["| 类型 | 名称 | GitHub | 仓库路径 | 名单版本 | 说明 |",
      "| --- | --- | --- | --- | --- | --- |"] +
     [.skills
      | sort_by([(.type as $t | ($order | index($t)) // 99), .name])[]
      | "| \(.type | cell) | \(.name | cell) | [\(.repo)](\($host)/\(.repo)) | \((.path // "") | pathcell) | \(if .version_kind == "commit" then (.version // "")[0:8] else (.version // "") end) | \((.description // "") | cell) |"
     ]) | .[]
  ' "$DATA_FILE"
}

render_md() {
  local tmp="$MD_FILE.tmp.$$"
  {
    printf '# 自选 Claude Skills 名单\n\n'
    printf '> 本文件由名单脚本（`fenix-selected-skills.sh` / `fenix-selected-skills.ps1`）从 [fenix-selected-skills.json](fenix-selected-skills.json) 自动生成，请勿手改。\n'
    jq -r '(.notes // [])[] | "> \(.)"' "$DATA_FILE"
    printf '\n共 %s 项 · 更新于 %s\n\n' "$(count_skills)" "$(date '+%Y-%m-%d %H:%M')"
    render_table
    printf '\n同步：`fenix-selected-skills.sh sync`（Windows：`fenix-selected-skills.cmd sync`） · 查状态：`fenix-selected-skills.sh status` · 帮助：`fenix-selected-skills.sh help`\n'
  } > "$tmp" && mv "$tmp" "$MD_FILE"
  ok "已生成 $MD_FILE"
}

latest_semver_tag() {
  LC_ALL=C awk '
    function numcmp(a, b) {
      sub(/^0+/, "", a); sub(/^0+/, "", b)
      if (a == "") a = "0"
      if (b == "") b = "0"
      if (length(a) != length(b)) return length(a) - length(b)
      if (("x" a) == ("x" b)) return 0
      return (("x" a) > ("x" b)) ? 1 : -1
    }
    function newer(major, minor, patch, pre,    c, na, nb, i, a, b, an, bn) {
      c = numcmp(major, best_major); if (c != 0) return c > 0
      c = numcmp(minor, best_minor); if (c != 0) return c > 0
      c = numcmp(patch, best_patch); if (c != 0) return c > 0
      if (pre == "" && best_pre != "") return 1
      if (pre != "" && best_pre == "") return 0
      if (pre == "") return 0
      na = split(pre, a, "."); nb = split(best_pre, b, ".")
      for (i = 1; i <= na && i <= nb; i++) {
        an = (a[i] ~ /^[0-9]+$/); bn = (b[i] ~ /^[0-9]+$/)
        if (an && bn) c = numcmp(a[i], b[i])
        else if (an != bn) c = an ? -1 : 1
        else if (("x" a[i]) != ("x" b[i])) c = (("x" a[i]) > ("x" b[i])) ? 1 : -1
        else c = 0
        if (c != 0) return c > 0
      }
      return na > nb
    }
    {
      # 输入由 sed 的整标签正则拆成：原标签 major minor patch prerelease。
      # 整标签匹配让可选前缀取最长，与 PowerShell/.NET 的语义一致。
      tag = $1
      if (NF < 4) next
      pre = $5
      sub(/^-/, "", pre)
      if (best == "" || newer($2, $3, $4, pre)) {
        best = tag
        best_major = $2; best_minor = $3; best_patch = $4
        best_pre = pre
      }
    }
    END { if (best != "") print best }
  '
}

resolve_version() {
  # 输出 "tag<TAB>版本" 或 "commit<TAB>完整SHA"；前缀不参与 SemVer 大小比较
  local repo="$1" tags sha
  tags="$(retry_output 3 git ls-remote --tags --refs "$GITHUB/$repo.git" \
    | sed 's#.*refs/tags/##' \
    | grep -E '^([A-Za-z][A-Za-z0-9._-]*-)?v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' || true)"
  if [ -n "$tags" ]; then
    printf 'tag\t%s\n' "$(printf '%s\n' "$tags" | sed -E \
      's#^([A-Za-z][A-Za-z0-9._-]*-)?v?([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$#& \2 \3 \4 \5#' \
      | latest_semver_tag)"
    return 0
  fi
  sha="$(retry_output 3 git ls-remote "$GITHUB/$repo.git" HEAD | cut -f1)"
  [ -n "$sha" ] || return 1
  printf 'commit\t%s\n' "$sha"
}

update_entry_version() {
  local name="$1" ver="$2" kind="$3" now="$4" tmp="$DATA_FILE.tmp.$$"
  jq --arg n "$name" --arg v "$ver" --arg k "$kind" --arg t "$now" '
    .skills |= map(
      if .name == $n then .version = $v | .version_kind = $k | .checked_at = $t else . end
    )
  ' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
}

restore_entry() {
  local name="$1" entry="$2" tmp="$DATA_FILE.tmp.$$"
  jq --arg n "$name" --argjson entry "$entry" '
    .skills |= map(if .name == $n then $entry else . end)
  ' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
}

touch_updated_at() {
  local tmp="$DATA_FILE.tmp.$$"
  jq --arg d "$(date +%Y-%m-%d)" '.updated_at = $d' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
}

save_state_entry() {
  # save_state_entry <name> <repo> <path> <ver> <kind> <installed_at>
  local name="$1" repo="$2" path="$3" ver="$4" kind="$5" now="$6" tmp input=/dev/null
  mkdir -p "$(dirname "$STATE_FILE")" || return 1
  if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
    [ -f "$STATE_FILE" ] || return 1
    input="$STATE_FILE"
  fi
  tmp="$(mktemp "$STATE_FILE.tmp.XXXXXX")" || return 1
  if jq -es --arg n "$name" --arg r "$repo" --arg p "$path" --arg v "$ver" \
     --arg k "$kind" --arg t "$now" '
    (.[0] // {}) |
    .skills = (.skills // {}) | .skills[$n] = {
      repo: $r, path: $p, version: $v, version_kind: $k, installed_at: $t
    }
  ' "$input" > "$tmp" && mv "$tmp" "$STATE_FILE"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

write_marker() {
  local marker="$1/.skill-manager.json" tmp
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  fi
  tmp="$(mktemp "$marker.tmp.XXXXXX")" || return 1
  if jq -n --arg r "$2" --arg p "$3" --arg v "$4" --arg k "$5" --arg t "$6" --argjson pending "${7:-false}" \
    '{repo: $r, path: $p, version: $v, version_kind: $k, installed_at: $t}
     | if $pending then .adoption_pending = true else . end' \
    > "$tmp" && mv "$tmp" "$marker"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

adopt_skill() {
  local name="$1" target="$2" repo="$3" path="$4" ver="$5" kind="$6" now="$7"
  local marker="$target/.skill-manager.json"
  if { [ -e "$marker" ] || [ -L "$marker" ]; } &&
     ! { [ -f "$marker" ] && [ ! -L "$marker" ] && jq -e '.adoption_pending == true' "$marker" >/dev/null 2>&1; }; then
    err "$name：收编标记路径已被占用（$marker）"
    return 1
  fi
  if ! write_marker "$target" "$repo" "$path" "$ver" "$kind" "$now" true; then
    err "$name：无法写入收编标记（$marker）"
    return 1
  fi
  if ! save_state_entry "$name" "$repo" "$path" "$ver" "$kind" "$now"; then
    err "$name：收编状态写入失败（$STATE_FILE）"
    rm -f "$marker" || err "$name：无法撤销新建标记，请检查 $marker"
    return 1
  fi
}

rollback_install() {
  local name="$1" target="$2" old_dest="$3" tmp="$4"
  if [ -e "$old_dest" ] || [ -L "$old_dest" ]; then
    if [ -e "$target" ] || [ -L "$target" ] || ! mv "$old_dest" "$target"; then
      err "$name：无法恢复原目录，备份保留在 $old_dest"
      return 1
    fi
  fi
  rm -rf "$tmp"
}

fetch_skill_md() {
  # fetch_skill_md <repo> <version> <path> <outfile>
  # 只抓单个 SKILL.md：先 raw，失败后走 GitHub API
  local repo="$1" ver="$2" path="$3" out="$4" api_path
  if [ -n "$path" ] && [ "$path" != "." ]; then
    api_path="$path/SKILL.md"
  else
    api_path="SKILL.md"
  fi
  if curl -fsS --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 15 -o "$out" \
    "https://raw.githubusercontent.com/$repo/$ver/$api_path" 2>/dev/null; then
    return 0
  fi
  if command -v gh >/dev/null 2>&1 && gh api "repos/$repo/contents/$api_path?ref=$ver" \
    -H "Accept: application/vnd.github.raw" > "$out" 2>/dev/null; then
    [ -s "$out" ] && return 0
  fi
  if curl -fsS --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 15 \
    -H "Accept: application/vnd.github.raw" \
    -o "$out" "https://api.github.com/repos/$repo/contents/$api_path?ref=$ver" 2>/dev/null; then
    return 0
  fi
  return 1
}

fetch_repo() {
  # fetch_repo <repo> <version> <kind> <dest> <path>
  # 只下载所需子目录：大仓库用 blobless + sparse checkout，避免整仓下载。
  # 网络失败自动重试；成功时吞掉 git 的提示，失败时输出最后一次错误。
  local repo="$1" ver="$2" kind="$3" dest="$4" path="$5" sparse=0 filter="" expected actual
  if [ -n "$path" ] && [ "$path" != "." ]; then sparse=1; fi

  if [ "$kind" = "tag" ]; then
    if [ "$sparse" = "1" ]; then
      retry_clone "$dest" git -c advice.detachedHead=false clone --quiet --no-checkout --depth 1 \
        --filter=blob:none --sparse "$GITHUB/$repo.git" || return 1
    else
      retry_clone "$dest" git -c advice.detachedHead=false clone --quiet --no-checkout --depth 1 \
        "$GITHUB/$repo.git" || return 1
    fi
    retry_git 3 git -C "$dest" fetch --quiet --depth 1 origin "refs/tags/$ver" || return 1
    if [ "$sparse" = "1" ]; then
      retry_git 2 git -C "$dest" sparse-checkout set --no-cone "/$path/" || return 1
    fi
    retry_git 2 git -c advice.detachedHead=false -C "$dest" checkout --quiet FETCH_HEAD || return 1
    expected="$(git -C "$dest" rev-parse 'FETCH_HEAD^{commit}')" || return 1
    actual="$(git -C "$dest" rev-parse 'HEAD^{commit}')" || return 1
    [ "$actual" = "$expected" ] || return 1
  else
    rm -rf "$dest"
    git init --quiet "$dest" || return 1
    git -C "$dest" remote add origin "$GITHUB/$repo.git" || return 1
    if [ "$sparse" = "1" ]; then
      git -C "$dest" config remote.origin.promisor true || return 1
      git -C "$dest" config remote.origin.partialclonefilter blob:none || return 1
      git -C "$dest" sparse-checkout init --no-cone >/dev/null 2>&1 || return 1
      printf '/%s/\n' "$path" > "$dest/.git/info/sparse-checkout"
      filter="--filter=blob:none"
    fi
    retry_git 3 git -C "$dest" fetch --quiet --depth 1 $filter origin "$ver" || return 1
    retry_git 2 git -c advice.detachedHead=false -C "$dest" checkout --quiet FETCH_HEAD || return 1
  fi
}

install_one() {
  local name="$1" force="$2" backup="${3:-0}"
  local repo path ver kind target src tmp fields backup_dir old_dest now staged managed
  if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    err "名称不合法：$name（只允许小写字母、数字、连字符）"
    return 1
  fi
  if ! jq -e --arg n "$name" 'any(.skills[]; .name == $n)' "$DATA_FILE" >/dev/null 2>&1; then
    err "名单中没有「$name」"
    return 1
  fi
  fields="$(jq -r --arg n "$name" '.skills[] | select(.name == $n)
    | [(.repo // ""), (if (.path // "") == "" then "." else .path end),
       (.version // ""), (.version_kind // "")]
    | map(tostring | gsub("[\u001f\n\r]"; "\\n")) | join("\u001f")' "$DATA_FILE")"
  IFS="$IFS_SEP" read -r repo path ver kind <<< "$fields"
  path="$(normalize_skill_path "$path")"
  if ! valid_skill_path "$path"; then
    err "$name：path 不合法（$path）"
    return 1
  fi
  if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    err "$name：repo 不合法（$repo）"
    return 1
  fi
  if [ -z "$ver" ]; then
    err "$name：版本为空，先运行 refresh $name"
    return 1
  fi
  if [ "$path" = "." ]; then
    warn "$name：技能位于仓库根目录，无法只取子目录，将下载整个仓库"
  fi

  target="$SKILLS_DIR/$name"
  managed=0
  if is_managed "$name"; then managed=1; fi
  if { [ -e "$target" ] || [ -L "$target" ]; } && [ "$managed" = "0" ] && [ "$force" != "1" ]; then
    warn "$name：$target 已存在且不是本工具安装，跳过（--force 可覆盖）"
    return 0
  fi

  mkdir -p "$SKILLS_DIR"
  tmp="$(mktemp -d "$SKILLS_DIR/.install-$name.XXXXXX")"
  TMP_ROOT="$tmp"
  info "$name：下载 $repo@$(fmt_ver "$kind" "$ver")"
  if ! fetch_repo "$repo" "$ver" "$kind" "$tmp/repo" "$path"; then
    err "$name：下载失败（$repo@$(fmt_ver "$kind" "$ver")）"
    rm -rf "$tmp"
    TMP_ROOT=""
    return 1
  fi

  src="$tmp/repo"
  if [ "$path" != "." ]; then src="$tmp/repo/$path"; fi
  if [ ! -f "$src/SKILL.md" ]; then
    err "$name：下载内容缺少 SKILL.md，请检查 path（当前：$path）"
    rm -rf "$tmp"
    TMP_ROOT=""
    return 1
  fi

  staged="$tmp/staged"
  if ! mkdir -p "$staged"; then
    err "$name：无法创建暂存目录，安装已取消"
    rm -rf "$tmp"; TMP_ROOT=""
    return 1
  fi
  if [ "$path" != "." ]; then
    if ! cp -R "$src/." "$staged/"; then
      err "$name：复制到暂存目录失败，原安装保持不变"
      rm -rf "$tmp"; TMP_ROOT=""
      return 1
    fi
  elif ! ( cd "$tmp/repo" && tar --exclude=.git -cf - . ) | ( cd "$staged" && tar -xf - ); then
    err "$name：打包复制到暂存目录失败，原安装保持不变"
    rm -rf "$tmp"; TMP_ROOT=""
    return 1
  fi
  if [ ! -f "$staged/SKILL.md" ]; then
    err "$name：暂存内容缺少有效 SKILL.md，原安装保持不变"
    rm -rf "$tmp"; TMP_ROOT=""
    return 1
  fi
  now="$(date '+%Y-%m-%d %H:%M')"
  if ! write_marker "$staged" "$repo" "$path" "$ver" "$kind" "$now"; then
    err "$name：暂存标记写入失败，原安装保持不变"
    rm -rf "$tmp"; TMP_ROOT=""
    return 1
  fi

  old_dest="$tmp/old"
  backup_dir=""
  TMP_ROOT=""
  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ "$managed" = "0" ] && [ "$backup" = "1" ]; then
      backup_dir="$SKILLS_DIR/.backups/$name-$(date '+%Y%m%d-%H%M%S')-$$"
      mkdir -p "$(dirname "$backup_dir")"
      old_dest="$backup_dir"
    elif [ "$managed" = "0" ]; then
      warn "$name：覆盖非本工具管理的目录 $target"
    fi
    if ! mv "$target" "$old_dest"; then
      err "$name：无法移走原目录，安装已取消"
      rm -rf "$tmp"
      TMP_ROOT=""
      return 1
    fi
    if [ -n "$backup_dir" ]; then warn "$name：已备份原目录到 $backup_dir"; fi
  fi

  if ! mv "$staged" "$target"; then
    err "$name：替换目录失败"
    rollback_install "$name" "$target" "$old_dest" "$tmp"
    return 1
  fi
  if ! save_state_entry "$name" "$repo" "$path" "$ver" "$kind" "$now"; then
    err "$name：状态写入失败"
    rm -rf "$target" || err "$name：无法清理新目录 $target"
    rollback_install "$name" "$target" "$old_dest" "$tmp"
    return 1
  fi
  if [ -z "$backup_dir" ] && [ -e "$old_dest" ]; then rm -rf "$old_dest"; fi

  rm -rf "$tmp"
  TMP_ROOT=""
  ok "$name 已安装到 $target（$(fmt_ver "$kind" "$ver")）"
}

cmd_list() {
  render_table
}

cmd_render() {
  render_md
}

cmd_refresh() {
  local names=() a n repo latest new_kind new_ver
  for a in "$@"; do
    case "$a" in
      -*) die "未知参数：$a" ;;
      *) names+=("$a") ;;
    esac
  done
  if [ ${#names[@]} -eq 0 ]; then
    while IFS= read -r n; do names+=("$n"); done < <(jq -r '.skills[].name' "$DATA_FILE")
  fi
  start_cache
  for n in "${names[@]}"; do
    if ! jq -e --arg n "$n" 'any(.skills[]; .name == $n)' "$DATA_FILE" >/dev/null 2>&1; then
      warn "$n 不在名单中，跳过"
      continue
    fi
    repo="$(jq -r --arg n "$n" '.skills[] | select(.name == $n) | .repo' "$DATA_FILE")"
    if ! latest="$(resolve_version_cached "$repo")"; then
      warn "$n：查询 $repo 失败（网络或仓库不存在）"
      continue
    fi
    new_kind="${latest%%$'\t'*}"
    new_ver="${latest#*$'\t'}"
    update_entry_version "$n" "$new_ver" "$new_kind" "$(date '+%Y-%m-%d %H:%M')"
    ok "$n：$(fmt_ver "$new_kind" "$new_ver")"
  done
  touch_updated_at
  render_md
}

cmd_install() {
  local force=0 n failed=0 names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      --target) [ $# -ge 2 ] || die "--target 需要参数"; apply_target_arg "$2"; shift 2 ;;
      --target=*) apply_target_arg "${1#*=}"; shift ;;
      -*) die "未知参数：$1" ;;
      *) names+=("$1"); shift ;;
    esac
  done
  if [ ${#names[@]} -eq 0 ]; then
    while IFS= read -r n; do install_one "$n" "$force" || failed=1; done < <(jq -r '.skills[].name' "$DATA_FILE")
  else
    for n in "${names[@]}"; do install_one "$n" "$force" || failed=1; done
  fi
  [ "$failed" = "0" ]
}

cmd_update() {
  local names=() n repo path latest new_kind new_ver old_ver old_kind inst source old_repo old_path original fields
  local failed=0 source_changed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || die "--target 需要参数"; apply_target_arg "$2"; shift 2 ;;
      --target=*) apply_target_arg "${1#*=}"; shift ;;
      -*) die "未知参数：$1" ;;
      *) names+=("$1"); shift ;;
    esac
  done
  if [ ${#names[@]} -eq 0 ]; then
    if [ -f "$STATE_FILE" ]; then
      while IFS= read -r n; do names+=("$n"); done < <(jq -r '.skills | keys[]' "$STATE_FILE")
    fi
    [ ${#names[@]} -gt 0 ] || die "还没有安装记录，先运行 ./fenix-selected-skills.sh sync 或 install"
  fi
  start_cache
  for n in "${names[@]}"; do
    if ! jq -e --arg n "$n" 'any(.skills[]; .name == $n)' "$DATA_FILE" >/dev/null 2>&1; then
      warn "$n 不在名单中，跳过"
      failed=1
      continue
    fi
    original="$(jq -c --arg n "$n" '.skills[] | select(.name == $n)' "$DATA_FILE")"
    fields="$(jq -r --arg n "$n" '.skills[] | select(.name == $n)
      | [(.repo // ""), (.path // "")] | map(tostring) | join("\u001f")' "$DATA_FILE")"
    IFS="$IFS_SEP" read -r repo path <<< "$fields"
    path="$(normalize_skill_path "$path")"
    if ! latest="$(resolve_version_cached "$repo")"; then
      warn "$n：查询 $repo 失败，跳过"
      failed=1
      continue
    fi
    new_kind="${latest%%$'\t'*}"
    new_ver="${latest#*$'\t'}"
    if [ ! -d "$SKILLS_DIR/$n" ] && is_managed "$n"; then
      update_entry_version "$n" "$new_ver" "$new_kind" "$(date '+%Y-%m-%d %H:%M')"
      info "$n：技能目录缺失，按最新版重新安装"
      if ! install_one "$n" 1; then
        restore_entry "$n" "$original"
        failed=1
      fi
      continue
    fi
    if ! inst="$(installed_version "$n")"; then
      warn "$n 尚未安装或没有版本记录，跳过（用 sync）"
      continue
    fi
    old_kind="${inst%%"$IFS_SEP"*}"
    old_ver="${inst#*"$IFS_SEP"}"
    old_repo=""
    old_path=""
    if source="$(installed_source "$n")"; then
      IFS="$IFS_SEP" read -r old_repo old_path <<< "$source"
      old_path="$(normalize_skill_path "$old_path")"
    fi
    source_changed=0
    if [ "$old_repo" != "$repo" ] || [ "$old_path" != "$path" ]; then source_changed=1; fi
    update_entry_version "$n" "$new_ver" "$new_kind" "$(date '+%Y-%m-%d %H:%M')"
    if [ "$new_ver" = "$old_ver" ] && [ "$new_kind" = "$old_kind" ] && [ "$source_changed" = "0" ]; then
      ok "$n 已是最新（$(fmt_ver "$new_kind" "$new_ver")）"
    else
      if [ "$source_changed" = "1" ]; then
        info "$n：技能来源变化（$old_repo/$old_path → $repo/$path）"
      else
        info "$n：$(fmt_ver "$old_kind" "$old_ver") → $(fmt_ver "$new_kind" "$new_ver")"
      fi
      if ! install_one "$n" 1; then
        restore_entry "$n" "$original"
        failed=1
      fi
    fi
  done
  touch_updated_at
  render_md
  [ "$failed" = "0" ]
}

cmd_sync() {
  local force=0 dry=0 failed=0 n repo path ver kind latest new_kind new_ver target sname inst old_kind old_ver fields missing_md original
  local source old_repo old_path source_changed=0
  local names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      --dry-run|-n) dry=1; shift ;;
      --target) [ $# -ge 2 ] || die "--target 需要参数"; apply_target_arg "$2"; shift 2 ;;
      --target=*) apply_target_arg "${1#*=}"; shift ;;
      -*) die "未知参数：$1" ;;
      *) names+=("$1"); shift ;;
    esac
  done
  if [ ${#names[@]} -eq 0 ]; then
    while IFS= read -r n; do names+=("$n"); done < <(jq -r '.skills[].name' "$DATA_FILE")
  fi
  start_cache
  info "目标目录：$SKILLS_DIR"
  for n in "${names[@]}"; do
    if ! jq -e --arg n "$n" 'any(.skills[]; .name == $n)' "$DATA_FILE" >/dev/null 2>&1; then
      warn "$n 不在名单中，跳过"
      failed=1
      continue
    fi
    original="$(jq -c --arg n "$n" '.skills[] | select(.name == $n)' "$DATA_FILE")"
    fields="$(jq -r --arg n "$n" '.skills[] | select(.name == $n)
      | [(.repo // ""), (if (.path // "") == "" then "." else .path end),
         (.version // ""), (.version_kind // "")]
      | map(tostring | gsub("[\u001f\n\r]"; "\\n")) | join("\u001f")' "$DATA_FILE")"
    IFS="$IFS_SEP" read -r repo path ver kind <<< "$fields"
    path="$(normalize_skill_path "$path")"
    if ! latest="$(resolve_version_cached "$repo")"; then
      warn "$n：查询 $repo 失败，跳过"
      failed=1
      continue
    fi
    new_kind="${latest%%$'\t'*}"
    new_ver="${latest#*$'\t'}"
    if [ "$dry" != "1" ]; then
      update_entry_version "$n" "$new_ver" "$new_kind" "$(date '+%Y-%m-%d %H:%M')"
    fi

    target="$SKILLS_DIR/$n"
    missing_md=0
    if [ ! -d "$target" ]; then
      if { [ -e "$target" ] || [ -L "$target" ]; } && [ "$force" != "1" ]; then
        warn "$n：$target 不是目录且未纳入管理，跳过（--force 可备份并替换）"
        continue
      fi
      if [ "$dry" = "1" ]; then
        if [ -e "$target" ] || [ -L "$target" ]; then
          info "[dry-run] $n：同名非目录将备份并替换为 $(fmt_ver "$new_kind" "$new_ver")"
        else
          info "[dry-run] $n：将安装 $(fmt_ver "$new_kind" "$new_ver")"
        fi
      else
        info "$n：目标缺失或不是目录，安装最新版"
        if ! install_one "$n" "$force" "$force"; then
          restore_entry "$n" "$original"
          failed=1
        fi
      fi
      continue
    fi

    if [ ! -f "$target/SKILL.md" ]; then
      warn "$n：$target 缺少 SKILL.md，按待更新处理"
      missing_md=1
    fi
    sname="$(read_skill_name "$target/SKILL.md")"
    if [ -n "$sname" ] && [ "$sname" != "$n" ]; then
      warn "$n：目录名与 SKILL.md 的 name（$sname）不一致"
    fi

    if inst="$(installed_version "$n")"; then
      old_kind="${inst%%"$IFS_SEP"*}"
      old_ver="${inst#*"$IFS_SEP"}"
      old_repo=""
      old_path=""
      if source="$(installed_source "$n")"; then
        IFS="$IFS_SEP" read -r old_repo old_path <<< "$source"
        old_path="$(normalize_skill_path "$old_path")"
      fi
      source_changed=0
      if [ "$old_repo" != "$repo" ] || [ "$old_path" != "$path" ]; then source_changed=1; fi
      if [ "$old_ver" = "$new_ver" ] && [ "$old_kind" = "$new_kind" ] && [ "$missing_md" = "0" ] && [ "$source_changed" = "0" ]; then
        ok "$n 已是最新（$(fmt_ver "$new_kind" "$new_ver")）"
      elif [ "$dry" = "1" ]; then
        if [ "$source_changed" = "1" ]; then
          info "[dry-run] $n：技能来源变化（$old_repo/$old_path → $repo/$path），将重新安装"
        else
          info "[dry-run] $n：$(fmt_ver "$old_kind" "$old_ver") → $(fmt_ver "$new_kind" "$new_ver")"
        fi
      else
        if [ "$source_changed" = "1" ]; then
          info "$n：技能来源变化（$old_repo/$old_path → $repo/$path），重新安装"
        else
          info "$n：$(fmt_ver "$old_kind" "$old_ver") → $(fmt_ver "$new_kind" "$new_ver")"
        fi
        if ! install_one "$n" 1; then
          restore_entry "$n" "$original"
          failed=1
        fi
      fi
      continue
    fi

    # 已存在但没有版本记录：用 SKILL.md 内容判断是否与最新版一致
    TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/skill-md.XXXXXX")"
    if fetch_skill_md "$repo" "$new_ver" "$path" "$TMP_FILE"; then
      if cmp -s "$TMP_FILE" "$target/SKILL.md"; then
        if [ "$dry" = "1" ]; then
          info "[dry-run] $n：内容与最新版一致，将纳入管理"
        elif adopt_skill "$n" "$target" "$repo" "$path" "$new_ver" "$new_kind" "$(date '+%Y-%m-%d %H:%M')"; then
          ok "$n 已存在且内容与最新版一致，纳入管理"
        else
          restore_entry "$n" "$original"
          failed=1
        fi
      elif [ "$force" != "1" ]; then
        warn "$n：已存在但内容与最新版不同，跳过（--force 可备份并更新）"
      elif [ "$dry" = "1" ]; then
        info "[dry-run] $n：已存在但内容不同，将备份并更新"
      else
        info "$n：已存在但内容与最新版不同，备份后更新"
        if ! install_one "$n" 1 1; then
          restore_entry "$n" "$original"
          failed=1
        fi
      fi
    elif [ "$force" = "1" ]; then
      if [ "$dry" = "1" ]; then
        info "[dry-run] $n：无法校验远端内容，将备份并更新"
      else
        warn "$n：无法校验远端内容，按 --force 备份后更新"
        if ! install_one "$n" 1 1; then
          restore_entry "$n" "$original"
          failed=1
        fi
      fi
    else
      warn "$n：已存在但无法获取远端 SKILL.md 校验，跳过（--force 可备份并更新）"
    fi
    rm -f "$TMP_FILE"
    TMP_FILE=""
  done
  if [ "$dry" = "1" ]; then
    info "dry-run 结束，未改动文件"
  else
    touch_updated_at
    render_md
  fi
  [ "$failed" = "0" ]
}

cmd_status() {
  local n ver kind inst st iv ik v
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || die "--target 需要参数"; apply_target_arg "$2"; shift 2 ;;
      --target=*) apply_target_arg "${1#*=}"; shift ;;
      -*) die "未知参数：$1" ;;
      *) die "未知参数：$1" ;;
    esac
  done
  info "目标目录：$SKILLS_DIR"
  printf '%-30s %-12s %-12s %s\n' "名称" "已安装" "名单版本" "状态"
  while IFS="$IFS_SEP" read -r n ver kind; do
    inst="-"
    if iv="$(installed_version "$n")"; then
      ik="${iv%%"$IFS_SEP"*}"
      v="${iv#*"$IFS_SEP"}"
      inst="$(fmt_ver "$ik" "$v")"
    fi
    if [ "$inst" = "-" ]; then
      if [ -e "$SKILLS_DIR/$n" ] || [ -L "$SKILLS_DIR/$n" ]; then st="未托管"; else st="未安装"; fi
    elif [ "$ik" = "$kind" ] && [ "$v" = "$ver" ]; then
      st="已最新"
    else
      st="可更新"
    fi
    printf '%-30s %-12s %-12s %s\n' "$n" "$inst" "$(fmt_ver "$kind" "$ver")" "$st"
  done < <(jq -r '.skills[] | [(.name // ""), (.version // ""), (.version_kind // "")]
    | map(tostring | gsub("[\u001f\n\r]"; "\\n")) | join("\u001f")' "$DATA_FILE")
}

network_check() {
  local fail name code error_before="$errors"
  info "并发检查 $(count_skills) 个远端 SKILL.md…"
  fail="$(jq -rj '
      def normpath: (. // "") | gsub("^(\\./)+"; "") | gsub("/+$"; "")
        | gsub("/{2,}"; "/") | gsub("/\\./"; "/") | gsub("/\\.$"; "")
        | if . == "" then "." else . end;
      .skills[] | [(.name // ""), (.repo // ""), (.path | normpath), (.version // "")]
      | .[] | . + "\u0000"' "$DATA_FILE" \
    | xargs -0 -P 8 -n 4 bash -c '
        name="$1"; repo="$2"; path="$3"; ver="$4"
        if [ "$path" != "." ]; then
          raw="https://raw.githubusercontent.com/$repo/$ver/$path/SKILL.md"
          api="repos/$repo/contents/$path/SKILL.md?ref=$ver"
        else
          raw="https://raw.githubusercontent.com/$repo/$ver/SKILL.md"
          api="repos/$repo/contents/SKILL.md?ref=$ver"
        fi
        code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 10 \
          --retry 1 --retry-delay 1 "$raw" 2>/dev/null || true)
        [ -n "$code" ] || code=000
        raw_code="$code"
        if [ "$code" != "200" ]; then
          # raw.githubusercontent.com 在部分网络下不可达，回退到 GitHub API
          if command -v gh >/dev/null 2>&1 && gh api "$api" >/dev/null 2>&1; then
            code=200
          else
            code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 10 \
              -H "Accept: application/vnd.github+json" "https://api.github.com/$api" 2>/dev/null || true)
            [ -n "$code" ] || code=000
            # API 也不可达时保留 raw 的真实状态码（如 404），不要退化成 000
            if [ "$code" = "000" ] && [ "$raw_code" != "000" ]; then code="$raw_code"; fi
          fi
        fi
        [ "$code" = "200" ] || printf "%s\t%s\n" "$name" "$code"
      ' _ || true)"
  if [ -n "$fail" ]; then
    while IFS=$'\t' read -r name code; do
      if [ "$code" = "000" ]; then
        warn "$name：远端未验证（raw 与 GitHub API 均不可达）"
        net_fail=$((net_fail + 1))
      else
        err "$name：远端 SKILL.md 不可访问（HTTP $code）"
        errors=$((errors + 1))
      fi
    done <<< "$fail"
  fi
  if [ "$net_fail" -gt 0 ]; then
    warn "$net_fail 项因网络不可达未验证；网络恢复后重跑 check --network"
  elif [ "$errors" -eq "$error_before" ]; then
    ok "远端检查通过：$(count_skills) 项均可访问"
  fi
}

cmd_check() {
  local network=0 a errors=0 net_fail=0 name type repo path ver kind dups net_note=""
  for a in "$@"; do
    case "$a" in
      --network) network=1 ;;
      *) die "未知参数：$a" ;;
    esac
  done
  jq -e '(.skills | type) == "array" and (.skills | length) > 0' "$DATA_FILE" >/dev/null \
    || die "fenix-selected-skills.json 结构错误：skills 必须是非空数组"

  dups="$(jq -r '.skills[].name' "$DATA_FILE" | sort | uniq -d)"
  if [ -n "$dups" ]; then
    err "重复名称：$(printf '%s' "$dups" | tr '\n' ' ')"
    errors=$((errors + 1))
  fi

  while IFS="$IFS_SEP" read -r name type repo path ver kind; do
    path="$(normalize_skill_path "$path")"
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      err "名称不合法（需小写字母/数字/连字符）：$name"
      errors=$((errors + 1))
    fi
    if [ -z "$type" ]; then
      err "$name：type 为空"
      errors=$((errors + 1))
    fi
    if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      err "$name：repo 需为 owner/name（当前：$repo）"
      errors=$((errors + 1))
    fi
    if ! valid_skill_path "$path"; then
      err "$name：path 必须是相对路径、使用正斜杠且不能包含 ..（$path）"
      errors=$((errors + 1))
    fi
    if [ -z "$ver" ]; then
      err "$name：version 为空（先运行 ./fenix-selected-skills.sh refresh $name）"
      errors=$((errors + 1))
    fi
    if [ "$kind" != "tag" ] && [ "$kind" != "commit" ]; then
      err "$name：version_kind 只能是 tag 或 commit（当前：$kind）"
      errors=$((errors + 1))
    fi
  done < <(jq -r '.skills[] | [(.name // ""), (.type // ""), (.repo // ""),
      (if (.path // "") == "" then "." else .path end), (.version // ""), (.version_kind // "")]
    | map(tostring | gsub("[\u001f\n\r]"; "\\n")) | join("\u001f")' "$DATA_FILE")

  if [ "$network" = "1" ]; then
    need_curl
    network_check
    if [ "$net_fail" -gt 0 ]; then
      net_note="，$net_fail 项远端未验证（网络不可达）"
    else
      net_note="，远端均可访问"
    fi
  fi

  if [ "$errors" -gt 0 ]; then
    die "检查未通过：$errors 处问题"
  fi
  ok "检查通过：$(count_skills) 项，字段与路径格式正常${net_note}"
}

cmd_add() {
  local name="" type="" repo="" path="." desc="" do_refresh=1 a
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) [ $# -ge 2 ] || die "--name 需要参数"; name="$2"; shift 2 ;;
      --type) [ $# -ge 2 ] || die "--type 需要参数"; type="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "--repo 需要参数"; repo="$2"; shift 2 ;;
      --path) [ $# -ge 2 ] || die "--path 需要参数"; path="$2"; shift 2 ;;
      --desc) [ $# -ge 2 ] || die "--desc 需要参数"; desc="$2"; shift 2 ;;
      --no-refresh) do_refresh=0; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [ -n "$name" ] && [ -n "$type" ] && [ -n "$repo" ] || die "add 需要 --name、--type、--repo"
  path="$(normalize_skill_path "$path")"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "名称不合法：$name（只允许小写字母、数字、连字符）"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repo 不合法：$repo（需 owner/name）"
  valid_skill_path "$path" || die "path 不合法：$path（需相对路径、正斜杠且不能包含 ..）"
  if jq -e --arg n "$name" 'any(.skills[]; .name == $n)' "$DATA_FILE" >/dev/null 2>&1; then
    die "名单中已有「$name」"
  fi
  local tmp="$DATA_FILE.tmp.$$"
  jq --arg n "$name" --arg t "$type" --arg r "$repo" --arg p "$path" --arg d "$desc" '
    .skills += [{
      type: $t, name: $n, repo: $r, path: $p,
      version: "", version_kind: "commit", description: $d, checked_at: ""
    }]
  ' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
  ok "已添加 $name"
  if [ "$do_refresh" = "1" ]; then
    cmd_refresh "$name"
  else
    warn "未刷新版本，运行 ./fenix-selected-skills.sh refresh $name 补全"
    touch_updated_at
    render_md
  fi
}

cmd_remove() {
  [ $# -eq 1 ] || die "用法：./fenix-selected-skills.sh remove <名称>"
  local name="$1"
  if ! jq -e --arg n "$name" 'any(.skills[]; .name == $n)' "$DATA_FILE" >/dev/null 2>&1; then
    die "名单中没有「$name」"
  fi
  local tmp="$DATA_FILE.tmp.$$"
  jq --arg n "$name" '.skills |= map(select(.name != $n))' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
  ok "已从名单移除 $name（已安装目录 $SKILLS_DIR/$name 未删除）"
  touch_updated_at
  render_md
}

cmd_env() {
  local os kernel distro envkind git_v jq_v curl_v
  os="$(uname -s 2>/dev/null || echo unknown)"
  kernel="$(uname -r 2>/dev/null || echo unknown)"
  distro=""
  if [ -r /etc/os-release ]; then
    distro="$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -n 1)"
  fi
  if grep -qi microsoft /proc/version 2>/dev/null; then envkind="WSL"; else envkind="原生"; fi
  git_v="$(git --version 2>/dev/null)" || git_v="未安装"
  jq_v="$(jq --version 2>/dev/null)" || jq_v="未安装"
  if command -v curl >/dev/null 2>&1; then curl_v="$(curl --version 2>/dev/null | head -n 1)"; else curl_v="未安装"; fi
  printf '平台：%s %s\n' "$os" "$kernel"
  [ -n "$distro" ] && printf '发行版：%s\n' "$distro"
  printf '环境：%s\n' "$envkind"
  printf 'Bash：%s\n' "${BASH_VERSION:-unknown}"
  printf 'git：%s\n' "${git_v:-未安装}"
  printf 'jq：%s\n' "${jq_v:-未安装}"
  printf 'curl：%s\n' "${curl_v:-未安装}"
  printf '目标目录：%s\n' "$SKILLS_DIR"
  printf '脚本：%s\n' "$SCRIPT_DIR/fenix-selected-skills.sh"
  if grep -q $'\r' "$0" 2>/dev/null; then
    printf '警告：脚本含 CRLF 换行，Linux/WSL 下请转成 LF（dos2unix fenix-selected-skills.sh）\n'
  fi
}

cmd_help() {
  cat <<'EOF'
自选 Claude Skills 名单管理

用法：
  ./fenix-selected-skills.sh sync [名称...] [--dry-run] [--force] [--target user|project|目录]
                                       对齐安装：缺失则装、已装则比对版本并更新（推荐）
  ./fenix-selected-skills.sh install [名称...] [--force] [--target ...]
                                       按名单当前版本安装，默认跳过非托管同名目录
  ./fenix-selected-skills.sh update [名称...] [--target ...]
                                       已安装项有新版则重装
  ./fenix-selected-skills.sh status [--target ...]    安装状态与名单记录版本（不联网）
  ./fenix-selected-skills.sh env                      打印环境信息（平台 / 依赖 / 目标目录）
  ./fenix-selected-skills.sh list                     打印名单表格
  ./fenix-selected-skills.sh render                   重新生成 fenix-selected-skills.md
  ./fenix-selected-skills.sh refresh [名称...]         查询并写回最新版本（默认全部）
  ./fenix-selected-skills.sh check [--network]        校验名单；--network 验证远端 SKILL.md
  ./fenix-selected-skills.sh add --name N --type T --repo O/R [--path P] [--desc D] [--no-refresh]
                                       追加条目（--no-refresh 暂不查询版本）
  ./fenix-selected-skills.sh remove <名称>             从名单移除（不删已安装目录）
  ./fenix-selected-skills.sh help                     显示本帮助

示例：
  ./fenix-selected-skills.sh sync                     把用户级目录对齐到最新版
  ./fenix-selected-skills.sh sync docx pdf --dry-run  预览要做的变更
  ./fenix-selected-skills.sh sync --target project    对齐到当前目录的 .claude/skills
  ./fenix-selected-skills.sh sync --target /opt/skills
  ./fenix-selected-skills.sh install --force          覆盖已存在的同名目录
  ./fenix-selected-skills.sh add --name my-skill --type 工程工具 --repo me/my-skills --path skills/my-skill

跨平台：
  macOS / Linux / WSL 使用 fenix-selected-skills.sh；Windows PowerShell 使用 fenix-selected-skills.ps1（或 fenix-selected-skills.cmd）。
  Git Bash / MSYS / Cygwin 下运行 fenix-selected-skills.sh 会自动转交 fenix-selected-skills.ps1；
  非 Windows 上运行 fenix-selected-skills.ps1 会自动转交 fenix-selected-skills.sh。
  Windows 需要 Git for Windows；macOS 可用 brew 安装 git/jq/curl；
  Debian/Ubuntu 可用 apt-get 安装 git/jq/curl。

路径与依赖：
  目标目录：--target user（默认 ~/.claude/skills）、project（当前目录/.claude/skills）
            或任意目录；CLAUDE_SKILLS_DIR 可覆盖 user
  状态文件：<目标目录>/.skills-manager.json；SKILLS_STATE_FILE 可覆盖
  path 会自动归一化：去掉开头的 ./、结尾的 /、重复的 / 和内部的 /.
  依赖：git、jq；check --network 另需 curl

下载策略：
  安装先下载并校验到临时目录，成功后才替换旧目录，失败保留原版本。
  安装只拉取 skills[].path 对应的子目录（git blobless + sparse checkout），
  不会下载整个仓库；仅当 path 为仓库根目录时才整仓浅克隆。
  check --network 只读取各 skill 的 SKILL.md 校验，不下载仓库。
  sync/update 会联网并把版本写回名单 JSON 和生成的 Markdown；sync --dry-run 不写任何文件。
  sync/install/update 任一安装失败时最终返回非零；sync/update 恢复失败条目的原 JSON 版本记录。
  版本不变但 repo/path 变化时也会重新安装。
  非托管同名目录只有内容与远端一致时才直接纳入管理；内容不同或无法校验时，
  必须加 --force 才会备份到 <目标目录>/.backups/<名称>-<时间> 后替换。
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    help|-h|--help) [ $# -eq 0 ] || die "help 不接受参数"; cmd_help ;;
    env) [ $# -eq 0 ] || die "env 不接受参数"; cmd_env ;;
    list) [ $# -eq 0 ] || die "list 不接受参数"; need_jq; require_data; cmd_list ;;
    render) [ $# -eq 0 ] || die "render 不接受参数"; need_jq; require_data; cmd_render ;;
    refresh) need_jq; need_git; require_data; cmd_refresh "$@" ;;
    sync) need_jq; need_git; require_data; cmd_sync "$@" ;;
    install) need_jq; need_git; require_data; cmd_install "$@" ;;
    update) need_jq; need_git; require_data; cmd_update "$@" ;;
    status) need_jq; require_data; cmd_status "$@" ;;
    check) need_jq; require_data; cmd_check "$@" ;;
    add) need_jq; need_git; require_data; cmd_add "$@" ;;
    remove) need_jq; require_data; cmd_remove "$@" ;;
    *) die "未知命令：$cmd（运行 ./fenix-selected-skills.sh help）" ;;
  esac
}

main "$@"
