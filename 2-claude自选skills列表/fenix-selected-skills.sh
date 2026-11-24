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
#   status [--target ...]    查看安装状态与最新版本
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
    if [ -f "$SCRIPT_DIR/fenix-selected-skills.ps1" ] && command -v powershell.exe >/dev/null 2>&1; then
      exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/fenix-selected-skills.ps1" "$@"
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

is_managed() {
  local name="$1"
  if [ -f "$STATE_FILE" ] && jq -e --arg n "$name" '.skills[$n] != null' "$STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi
  [ -f "$SKILLS_DIR/$name/.skill-manager.json" ]
}

installed_version() {
  # 输出 "kind<TAB>version"；未安装或无法判定时返回 1
  local name="$1"
  if [ -f "$STATE_FILE" ] && jq -e --arg n "$name" '.skills[$n] != null' "$STATE_FILE" >/dev/null 2>&1; then
    jq -r --arg n "$name" '.skills[$n] | [.version_kind, .version] | @tsv' "$STATE_FILE"
    return 0
  fi
  if [ -f "$SKILLS_DIR/$name/.skill-manager.json" ]; then
    jq -r '[.version_kind, .version] | @tsv' "$SKILLS_DIR/$name/.skill-manager.json" 2>/dev/null || return 1
    return 0
  fi
  return 1
}

read_skill_name() {
  # 读取 SKILL.md frontmatter 的 name
  [ -f "$1" ] || return 0
  awk -F': *' '/^name:/ { print $2; exit }' "$1" | tr -d '"' | tr -d '\r'
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
    (["| 类型 | 名称 | GitHub | 仓库路径 | 最新版本 | 说明 |",
      "| --- | --- | --- | --- | --- | --- |"] +
     [.skills
      | sort_by([(.type as $t | ($order | index($t)) // 99), .name])[]
      | "| \(.type) | \(.name) | [\(.repo)](\($host)/\(.repo)) | \(if (.path // "") == "" or .path == "." then "—" else .path end) | \(if .version_kind == "commit" then .version[0:8] else .version end) | \(.description // "") |"
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
    printf '\n同步：`fenix-selected-skills.sh sync`（Windows：`fenix-selected-skills.ps1 sync`） · 查状态：`fenix-selected-skills.sh status` · 帮助：`fenix-selected-skills.sh help`\n'
  } > "$tmp" && mv "$tmp" "$MD_FILE"
  ok "已生成 $MD_FILE"
}

resolve_version() {
  # 输出 "tag<TAB>版本" 或 "commit<TAB>完整SHA"
  local repo="$1" tags sha
  tags="$(retry_output 3 git ls-remote --tags --refs "$GITHUB/$repo.git" \
    | sed 's#.*refs/tags/##' \
    | grep -E '^([A-Za-z][A-Za-z0-9._-]*-)?v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?(\+[0-9A-Za-z.]+)?$' || true)"
  if [ -n "$tags" ]; then
    printf 'tag\t%s\n' "$(printf '%s\n' "$tags" | sort -V | tail -n 1)"
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

touch_updated_at() {
  local tmp="$DATA_FILE.tmp.$$"
  jq --arg d "$(date +%Y-%m-%d)" '.updated_at = $d' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
}

save_state_entry() {
  # save_state_entry <name> <repo> <path> <ver> <kind> <installed_at>
  local name="$1" repo="$2" path="$3" ver="$4" kind="$5" now="$6" tmp
  mkdir -p "$(dirname "$STATE_FILE")"
  [ -f "$STATE_FILE" ] || printf '{"skills":{}}\n' > "$STATE_FILE"
  tmp="$STATE_FILE.tmp.$$"
  jq --arg n "$name" --arg r "$repo" --arg p "$path" --arg v "$ver" \
     --arg k "$kind" --arg t "$now" '
    .skills = (.skills // {}) | .skills[$n] = {
      repo: $r, path: $p, version: $v, version_kind: $k, installed_at: $t
    }
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

write_marker() {
  # write_marker <target> <repo> <path> <ver> <kind> <installed_at>
  jq -n --arg r "$2" --arg p "$3" --arg v "$4" --arg k "$5" --arg t "$6" \
    '{repo: $r, path: $p, version: $v, version_kind: $k, installed_at: $t}' \
    > "$1/.skill-manager.json"
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
  local repo="$1" ver="$2" kind="$3" dest="$4" path="$5" sparse=0 filter=""
  if [ -n "$path" ] && [ "$path" != "." ]; then sparse=1; fi

  if [ "$kind" = "tag" ]; then
    if [ "$sparse" = "1" ]; then
      retry_clone "$dest" git -c advice.detachedHead=false clone --quiet --depth 1 \
        --filter=blob:none --sparse --branch "$ver" "$GITHUB/$repo.git" || return 1
      retry_git 2 git -C "$dest" sparse-checkout set --no-cone "$path/" || return 1
    else
      retry_clone "$dest" git -c advice.detachedHead=false clone --quiet --depth 1 \
        --branch "$ver" "$GITHUB/$repo.git" || return 1
    fi
  else
    rm -rf "$dest"
    git init --quiet "$dest" || return 1
    git -C "$dest" remote add origin "$GITHUB/$repo.git" || return 1
    if [ "$sparse" = "1" ]; then
      git -C "$dest" config remote.origin.promisor true || return 1
      git -C "$dest" config remote.origin.partialclonefilter blob:none || return 1
      git -C "$dest" sparse-checkout init --no-cone >/dev/null 2>&1 || return 1
      printf '%s/\n' "$path" > "$dest/.git/info/sparse-checkout"
      filter="--filter=blob:none"
    fi
    retry_git 3 git -C "$dest" fetch --quiet --depth 1 $filter origin "$ver" || return 1
    retry_git 2 git -c advice.detachedHead=false -C "$dest" checkout --quiet FETCH_HEAD || return 1
  fi
}

install_one() {
  local name="$1" force="$2" backup="${3:-0}"
  local repo path ver kind desc target src tmp fields backup_dir
  if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    die "名称不合法：$name（只允许小写字母、数字、连字符）"
  fi
  if ! jq -e --arg n "$name" 'any(.skills[]; .name == $n)' "$DATA_FILE" >/dev/null 2>&1; then
    die "名单中没有「$name」"
  fi
  fields="$(jq -r --arg n "$name" '.skills[] | select(.name == $n)
    | [.repo, (.path // ""), .version, .version_kind, (.description // "")] | @tsv' "$DATA_FILE")"
  IFS=$'\t' read -r repo path ver kind desc <<< "$fields"
  case "$path" in
    /*|*"/../"*|".."*|*"/..") die "$name：path 不合法（$path）" ;;
  esac
  if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    die "$name：repo 不合法（$repo）"
  fi
  if [ -z "$path" ] || [ "$path" = "." ]; then
    warn "$name：技能位于仓库根目录，无法只取子目录，将下载整个仓库"
  fi

  target="$SKILLS_DIR/$name"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if is_managed "$name"; then
      rm -rf "$target"
    elif [ "$force" = "1" ]; then
      if [ "$backup" = "1" ]; then
        backup_dir="$SKILLS_DIR/.backups/$name-$(date '+%Y%m%d-%H%M%S')"
        mkdir -p "$(dirname "$backup_dir")"
        mv "$target" "$backup_dir"
        warn "$name：已备份原目录到 $backup_dir"
      else
        warn "$name：覆盖非本工具管理的目录 $target"
        rm -rf "$target"
      fi
    else
      warn "$name：$target 已存在且不是本工具安装，跳过（--force 可覆盖）"
      return 0
    fi
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-skill.XXXXXX")"
  TMP_ROOT="$tmp"
  info "$name：下载 $repo@$(fmt_ver "$kind" "$ver")"
  if ! fetch_repo "$repo" "$ver" "$kind" "$tmp/repo" "$path"; then
    err "$name：下载失败（$repo@$(fmt_ver "$kind" "$ver")）"
    rm -rf "$tmp"
    TMP_ROOT=""
    return 1
  fi

  src="$tmp/repo"
  if [ -n "$path" ] && [ "$path" != "." ]; then
    src="$tmp/repo/$path"
  fi
  if [ ! -f "$src/SKILL.md" ]; then
    err "$name：下载内容缺少 SKILL.md，请检查 path（当前：${path:-.}）"
    rm -rf "$tmp"
    TMP_ROOT=""
    return 1
  fi

  mkdir -p "$SKILLS_DIR" "$target"
  if [ -n "$path" ] && [ "$path" != "." ]; then
    cp -R "$src/." "$target/"
  else
    ( cd "$tmp/repo" && tar --exclude=.git -cf - . ) | ( cd "$target" && tar -xf - )
  fi

  local now="$(date '+%Y-%m-%d %H:%M')"
  save_state_entry "$name" "$repo" "$path" "$ver" "$kind" "$now"
  write_marker "$target" "$repo" "$path" "$ver" "$kind" "$now"

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
  local force=0 n names=()
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
    while IFS= read -r n; do install_one "$n" "$force" || true; done < <(jq -r '.skills[].name' "$DATA_FILE")
  else
    for n in "${names[@]}"; do install_one "$n" "$force" || true; done
  fi
}

cmd_update() {
  local names=() n repo latest new_kind new_ver old_ver old_kind inst fields
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
      continue
    fi
    fields="$(jq -r --arg n "$n" '.skills[] | select(.name == $n) | [.repo] | @tsv' "$DATA_FILE")"
    IFS=$'\t' read -r repo <<< "$fields"
    if ! latest="$(resolve_version_cached "$repo")"; then
      warn "$n：查询 $repo 失败，跳过"
      continue
    fi
    new_kind="${latest%%$'\t'*}"
    new_ver="${latest#*$'\t'}"
    if ! inst="$(installed_version "$n")"; then
      warn "$n 尚未安装或没有版本记录，跳过（用 sync）"
      continue
    fi
    old_kind="${inst%%$'\t'*}"
    old_ver="${inst#*$'\t'}"
    update_entry_version "$n" "$new_ver" "$new_kind" "$(date '+%Y-%m-%d %H:%M')"
    if [ "$new_ver" = "$old_ver" ] && [ "$new_kind" = "$old_kind" ]; then
      ok "$n 已是最新（$(fmt_ver "$new_kind" "$new_ver")）"
    else
      info "$n：$(fmt_ver "$old_kind" "$old_ver") → $(fmt_ver "$new_kind" "$new_ver")"
      install_one "$n" 1 || true
    fi
  done
  touch_updated_at
  render_md
}

cmd_sync() {
  local force=0 dry=0 n repo path ver kind latest new_kind new_ver target sname inst old_kind old_ver fields missing_md
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
      continue
    fi
    fields="$(jq -r --arg n "$n" '.skills[] | select(.name == $n)
      | [.repo, (.path // ""), .version, .version_kind] | @tsv' "$DATA_FILE")"
    IFS=$'\t' read -r repo path ver kind <<< "$fields"
    if ! latest="$(resolve_version_cached "$repo")"; then
      warn "$n：查询 $repo 失败，跳过"
      continue
    fi
    new_kind="${latest%%$'\t'*}"
    new_ver="${latest#*$'\t'}"
    update_entry_version "$n" "$new_ver" "$new_kind" "$(date '+%Y-%m-%d %H:%M')"

    target="$SKILLS_DIR/$n"
    missing_md=0
    if [ ! -d "$target" ]; then
      if [ "$dry" = "1" ]; then
        info "[dry-run] $n：将安装 $(fmt_ver "$new_kind" "$new_ver")"
      else
        info "$n：未安装，安装最新版"
        install_one "$n" 0 || true
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
      old_kind="${inst%%$'\t'*}"
      old_ver="${inst#*$'\t'}"
      if [ "$old_ver" = "$new_ver" ] && [ "$old_kind" = "$new_kind" ] && [ "$missing_md" = "0" ]; then
        ok "$n 已是最新（$(fmt_ver "$new_kind" "$new_ver")）"
      elif [ "$dry" = "1" ]; then
        info "[dry-run] $n：$(fmt_ver "$old_kind" "$old_ver") → $(fmt_ver "$new_kind" "$new_ver")"
      else
        info "$n：$(fmt_ver "$old_kind" "$old_ver") → $(fmt_ver "$new_kind" "$new_ver")"
        install_one "$n" 1 || true
      fi
      continue
    fi

    # 已存在但没有版本记录：用 SKILL.md 内容判断是否与最新版一致
    TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/skill-md.XXXXXX")"
    if fetch_skill_md "$repo" "$new_ver" "$path" "$TMP_FILE"; then
      if cmp -s "$TMP_FILE" "$target/SKILL.md"; then
        ok "$n 已存在且内容与最新版一致，纳入管理"
        if [ "$dry" != "1" ]; then
          save_state_entry "$n" "$repo" "$path" "$new_ver" "$new_kind" "$(date '+%Y-%m-%d %H:%M')"
          write_marker "$target" "$repo" "$path" "$new_ver" "$new_kind" "$(date '+%Y-%m-%d %H:%M')"
        fi
      elif [ "$dry" = "1" ]; then
        info "[dry-run] $n：已存在但内容不同，将备份并更新"
      else
        info "$n：已存在但内容与最新版不同，备份后更新"
        install_one "$n" 1 1 || true
      fi
    elif [ "$force" = "1" ]; then
      if [ "$dry" = "1" ]; then
        info "[dry-run] $n：无法校验远端内容，将备份并更新"
      else
        warn "$n：无法校验远端内容，按 --force 备份后更新"
        install_one "$n" 1 1 || true
      fi
    else
      warn "$n：已存在但无法获取远端 SKILL.md 校验，跳过（--force 可备份并更新）"
    fi
    rm -f "$TMP_FILE"
    TMP_FILE=""
  done
  touch_updated_at
  if [ "$dry" = "1" ]; then
    info "dry-run 结束，未改动文件"
  else
    render_md
  fi
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
  printf '%-30s %-12s %-12s %s\n' "名称" "已安装" "最新" "状态"
  while IFS=$'\t' read -r n ver kind; do
    inst="-"
    if iv="$(installed_version "$n")"; then
      inst="$(printf '%s\n' "$iv" | while IFS=$'\t' read -r ik v; do fmt_ver "$ik" "$v"; done)"
    fi
    if [ "$inst" = "-" ]; then
      st="未安装"
    elif [ "$inst" = "$(fmt_ver "$kind" "$ver")" ]; then
      st="已最新"
    else
      st="可更新"
    fi
    printf '%-30s %-12s %-12s %s\n' "$n" "$inst" "$(fmt_ver "$kind" "$ver")" "$st"
  done < <(jq -r '.skills[] | [.name, .version, .version_kind] | @tsv' "$DATA_FILE")
}

network_check() {
  local fail name code
  info "并发检查 $(count_skills) 个远端 SKILL.md…"
  fail="$(jq -r '.skills[] | [.name, .repo, (.path // ""), .version] | @tsv' "$DATA_FILE" \
    | xargs -P 8 -n 4 bash -c '
        name="$1"; repo="$2"; path="$3"; ver="$4"
        if [ -n "$path" ] && [ "$path" != "." ]; then
          raw="https://raw.githubusercontent.com/$repo/$ver/$path/SKILL.md"
          api="repos/$repo/contents/$path/SKILL.md?ref=$ver"
        else
          raw="https://raw.githubusercontent.com/$repo/$ver/SKILL.md"
          api="repos/$repo/contents/SKILL.md?ref=$ver"
        fi
        code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 10 \
          --retry 1 --retry-delay 1 "$raw" 2>/dev/null || true)
        if [ "$code" != "200" ]; then
          # raw.githubusercontent.com 在部分网络下不可达，回退到 GitHub API
          if command -v gh >/dev/null 2>&1 && gh api "$api" >/dev/null 2>&1; then
            code=200
          else
            code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 10 \
              -H "Accept: application/vnd.github+json" "https://api.github.com/$api" 2>/dev/null || true)
            [ -n "$code" ] || code=000
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
  else
    ok "远端检查通过：$(count_skills) 项均可访问"
  fi
}

cmd_check() {
  local network=0 a errors=0 net_fail=0 name type repo path ver kind dups net_note
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

  while IFS=$'\t' read -r name type repo path ver kind; do
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
    case "$path" in
      /*) err "$name：path 不能是绝对路径（$path）"; errors=$((errors + 1)) ;;
      *"/../"*|".."*|*"/..") err "$name：path 不能包含 ..（$path）"; errors=$((errors + 1)) ;;
    esac
    if [ -z "$ver" ]; then
      err "$name：version 为空（先运行 ./fenix-selected-skills.sh refresh $name）"
      errors=$((errors + 1))
    fi
    if [ "$kind" != "tag" ] && [ "$kind" != "commit" ]; then
      err "$name：version_kind 只能是 tag 或 commit（当前：$kind）"
      errors=$((errors + 1))
    fi
  done < <(jq -r '.skills[] | [.name, .type, .repo, (.path // ""), .version, .version_kind] | @tsv' "$DATA_FILE")

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
      --name) name="${2:-}"; shift 2 ;;
      --type) type="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --path) path="${2:-}"; shift 2 ;;
      --desc) desc="${2:-}"; shift 2 ;;
      --no-refresh) do_refresh=0; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [ -n "$name" ] && [ -n "$type" ] && [ -n "$repo" ] || die "add 需要 --name、--type、--repo"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "名称不合法：$name（只允许小写字母、数字、连字符）"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repo 不合法：$repo（需 owner/name）"
  case "$path" in
    /*|*"/../"*|".."*|*"/..") die "path 不合法：$path" ;;
  esac
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
  ./fenix-selected-skills.sh status [--target ...]    安装状态与最新版本
  ./fenix-selected-skills.sh env                      打印环境信息（平台 / 依赖 / 目标目录）
  ./fenix-selected-skills.sh list                     打印名单表格
  ./fenix-selected-skills.sh render                   重新生成 fenix-selected-skills.md
  ./fenix-selected-skills.sh refresh [名称...]         查询并写回最新版本（默认全部）
  ./fenix-selected-skills.sh check [--network]        校验名单；--network 验证远端 SKILL.md
  ./fenix-selected-skills.sh add --name N --type T --repo O/R [--path P] [--desc D]
                                       追加条目
  ./fenix-selected-skills.sh remove <名称>             从名单移除（不删已安装目录）

示例：
  ./fenix-selected-skills.sh sync                     把用户级目录对齐到最新版
  ./fenix-selected-skills.sh sync docx pdf --dry-run  预览要做的变更
  ./fenix-selected-skills.sh sync --target project    对齐到当前目录的 .claude/skills
  ./fenix-selected-skills.sh sync --target /opt/skills
  ./fenix-selected-skills.sh install --force          覆盖已存在的同名目录
  ./fenix-selected-skills.sh add --name my-skill --type 工程工具 --repo me/my-skills --path skills/my-skill

跨平台：
  macOS / Linux / WSL 使用 fenix-selected-skills.sh；Windows PowerShell 使用 fenix-selected-skills.ps1（或 fenix-selected-skills.cmd）。
  Git Bash / MSYS 下运行 fenix-selected-skills.sh 会自动转交 fenix-selected-skills.ps1；
  非 Windows 上运行 fenix-selected-skills.ps1 会自动转交 fenix-selected-skills.sh。
  Windows 需要 Git for Windows；macOS 可用 brew 安装 git/jq/curl；
  Debian/Ubuntu 可用 apt-get 安装 git/jq/curl。

路径与依赖：
  目标目录：--target user（默认 ~/.claude/skills）、project（当前目录/.claude/skills）
            或任意目录；CLAUDE_SKILLS_DIR 可覆盖 user
  状态文件：<目标目录>/.skills-manager.json
  依赖：git、jq；check --network 另需 curl

下载策略：
  安装只拉取 skills[].path 对应的子目录（git blobless + sparse checkout），
  不会下载整个仓库；仅当 path 为仓库根目录时才整仓浅克隆。
  check --network 只读取各 skill 的 SKILL.md 校验，不下载仓库。
  sync 更新已有但非本工具安装的同名目录时，会先备份到 <目标目录>/.backups/<名称>-<时间>。
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    help|-h|--help) cmd_help ;;
    env) cmd_env ;;
    list) need_jq; require_data; cmd_list ;;
    render) need_jq; require_data; cmd_render ;;
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
