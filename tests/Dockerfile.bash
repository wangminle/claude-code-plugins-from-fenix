# Docker Bash 回归测试镜像（FENIX_TEST_DOCKER_BASH=1）
# 构建：docker build -t fenix-selected-skills-bash:test -f tests/Dockerfile.bash tests
# 说明：测试脚本需要 git / jq / curl；bash:5 默认镜像不含这些工具。
FROM bash:5

RUN apk add --no-cache git jq curl ca-certificates