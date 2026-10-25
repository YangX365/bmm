#!/bin/bash
# ---------------------------------------------------------------------------
# 极简 pnpm 垫片（shim）
#
# 为什么需要它：
#   本镜像为了省 ~64MB 没有安装 pnpm / corepack，但应用启动脚本
#   scripts/db-init.mjs 在数据库首次初始化时会执行：
#       pnpm drizzle-kit generate
#       pnpm drizzle-kit migrate
#   （zx 通过 bash 执行，所以没有 pnpm 时会报
#    `/bin/bash: line 1: pnpm: command not found`）
#
#   这个垫片只做两件事，足够覆盖镜像内的所有用法：
#     1) pnpm <bin> [args...]        -> /app/node_modules/.bin/<bin> [args...]
#     2) pnpm run <script> [args...] -> 执行 package.json 里对应的 script
#
#   安装类命令（install/add/exec/dlx...）会明确报错，避免以为能改运行中的镜像。
# ---------------------------------------------------------------------------
set -euo pipefail

APP_DIR="${APP_DIR:-/app}"
VERSION="1.0.0"

usage() {
  cat >&2 <<EOF
pnpm shim ${VERSION}（镜像内未安装真正的 pnpm）

可用用法：
  pnpm <bin> [args...]          例：pnpm drizzle-kit generate
  pnpm run <script> [args...]   例：pnpm run db:test
  pnpm <script>                 例：pnpm start（若 script 存在则等价于 run）

不可用：install / add / remove / exec / dlx 等安装类命令（需在构建阶段完成）
EOF
}

case "${1:-}" in
  ""|-h|--help|help)
    usage
    exit $([ -n "${1:-}" ] && echo 0 || echo 127)
    ;;
  -v|--version|version)
    echo "${VERSION}"
    exit 0
    ;;
  # 安装/环境类命令：明确拒绝
  i|install|add|update|up|upgrade|remove|rm|uninstall|prune|exec|dlx|store|link|unlink|publish|pack|deploy|why|licenses|audit|init|create)
    echo "pnpm(shim): 镜像内没有真正的 pnpm，'$1' 不可用。" >&2
    echo "pnpm(shim): 依赖变更请在 Dockerfile 的构建阶段处理。" >&2
    exit 127
    ;;
  # 脚本执行：通过 package.json 解析
  run|run-script)
    shift
    [ "${1:-}" = "--" ] && shift
    script="${1:-}"
    if [ -z "$script" ]; then usage; exit 127; fi
    shift || true
    if ! cmd=$(node -e '
      const p = require(process.argv[1] + "/package.json");
      const v = (p.scripts || {})[process.argv[2]];
      if (!v) process.exit(1);
      process.stdout.write(v);
    ' "$APP_DIR" "$script" 2>/dev/null); then
      echo "pnpm(shim): package.json 中没有 script \"$script\"" >&2
      exit 127
    fi
    exec /bin/bash -c "$cmd"
    ;;
  # 其它：先当 pnpm script 处理，不存在再当二进制处理
  *)
    name="$1"
    shift || true
    if cmd=$(node -e '
      const p = require(process.argv[1] + "/package.json");
      const v = (p.scripts || {})[process.argv[2]];
      if (!v) process.exit(1);
      process.stdout.write(v);
    ' "$APP_DIR" "$name" 2>/dev/null); then
      exec /bin/bash -c "$cmd"
    fi
    bin="$APP_DIR/node_modules/.bin/$name"
    if [ ! -x "$bin" ]; then
      echo "pnpm(shim): 既不是 package.json 中的 script，也不是 $APP_DIR/node_modules/.bin/ 下的可执行文件：$name" >&2
      usage
      exit 127
    fi
    exec "$bin" "$@"
    ;;
esac
