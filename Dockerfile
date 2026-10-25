# Next 配置 output: standalone 可以减少镜像大小，因为它只会把用到的依赖打包到 .next/standalone/node_modules 下
# 但是还有一些重要依赖不会被打包，比如 zx、drizzle-kit 等，它们只有手动执行相关 scripts 才会被用到，不属于 Next 应用的一部分
# 已经尝试使用 COPY 手动复制这些依赖，但是很麻烦而且不好维护
# 所以还是使用普通的 output 模式，通过手动删除不必要的文件，可控制镜像大小仅增加 ~300Mb

# ============================================================
# 本机优化版（相对上游改动 4 处，均在注释中标注【优化 N】）
# 上游原始版本：git checkout -- Dockerfile
# ============================================================


FROM node:24-alpine AS base
# --- 本地适配：国内网络下 alpine 官方 CDN 不可达，改用清华镜像 ---
RUN sed -i 's#dl-cdn.alpinelinux.org#mirrors.tuna.tsinghua.edu.cn#g' /etc/apk/repositories
ENV COREPACK_NPM_REGISTRY=https://registry.npmmirror.com
RUN corepack enable && pnpm -v


FROM base AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json pnpm-lock.yaml .npmrc .

RUN pnpm install --frozen-lockfile


FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# docker 构建镜像时不需要预先配置数据库，所以不需要执行 db-init 脚本，这里直接 next build 就行
# 忽略构建错误，因为在 Github Action 中构建时，全是静态的类型检查会导致一些错误
RUN export IGNORE_BUILD_ERRORS=true && pnpm next build && pnpm prune --prod
# 清理一些体积较大的、运行时不需要的文件
RUN rm -rf doc .next/cache .next/trace \
node_modules/.pnpm/@types+* \
node_modules/.pnpm/caniuse* \
node_modules/.pnpm/@ant-design+icons* \
node_modules/.pnpm/vite* \
node_modules/.pnpm/typescript@* \
node_modules/.pnpm/eslint*
RUN find node_modules/.pnpm/ -type f -name "*.ts" -delete
# 【优化 1】删除仅构建期需要的编译器 / 非本平台原生二进制（约 -160MB）
#   @next/swc-linux-x64-musl 只在 next build 时用到，next start 不需要
#   lightningcss / @tailwindcss/* 是 Tailwind 构建期依赖，产物已写进 .next/static
#   @img/sharp-libvips-linux-x64 是 glibc 版本，alpine 用 musl 版本
RUN rm -rf node_modules/.pnpm/@next+swc-* \
node_modules/.pnpm/lightningcss-* \
node_modules/.pnpm/@tailwindcss+* \
node_modules/.pnpm/tailwindcss* \
node_modules/.pnpm/@esbuild+linux-x64@0.18.20 \
node_modules/.pnpm/@img+sharp-libvips-linux-x64@*
# 【优化 2】删除只在浏览器侧打包的 UI 库在 node_modules 里的副本（约 -100MB）
#   这些库已经通过 'use client' 打进 .next/static，服务端运行时不再 require 它们
RUN rm -rf node_modules/.pnpm/antd@* \
node_modules/.pnpm/@heroui+* \
node_modules/.pnpm/framer-motion@* \
node_modules/.pnpm/motion@* \
node_modules/.pnpm/motion-dom@* \
node_modules/.pnpm/motion-utils@* \
node_modules/.pnpm/rc-* \
node_modules/.pnpm/@rc-component+* \
node_modules/.pnpm/react-colorful@* \
node_modules/.pnpm/@dnd-kit+* \
node_modules/.pnpm/ahooks@* \
node_modules/.pnpm/i18next@*


# 【优化 3】runner 直接基于 node:24-alpine，不再继承 corepack 那层（约 -64MB），
#   也不再在容器启动时用 corepack 联网下载 pnpm
FROM node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
ENV NEXT_TELEMETRY_DISABLED=1
# zx 依赖 bash；【优化 4】顺带移除用不到的 npm / yarn / corepack（约 -23MB）
RUN sed -i 's#dl-cdn.alpinelinux.org#mirrors.tuna.tsinghua.edu.cn#g' /etc/apk/repositories \
 && apk add --no-cache bash \
 && rm -rf /usr/local/lib/node_modules/npm /opt/yarn-v1.22.22 \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg /usr/local/bin/corepack
COPY --from=builder /app .

EXPOSE 3000

# 等价于原来的 pnpm run start（先 db-init，再 next start），只是不再依赖 pnpm
CMD ["sh", "-c", "node_modules/.bin/tsx scripts/db-init.mjs -P && exec node_modules/.bin/next start"]
