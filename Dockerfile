# ---- 第 1 阶段：安装依赖 ----
FROM node:20-alpine AS deps
RUN corepack enable && corepack prepare pnpm@latest --activate
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm store prune && pnpm install --frozen-lockfile

# ---- 第 2 阶段：构建项目 ----
FROM node:20-alpine AS builder
RUN apk add --no-cache python3 make g++
RUN corepack enable && corepack prepare pnpm@latest --activate
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
COPY --from=deps /app/node_modules ./node_modules
RUN pnpm install --frozen-lockfile --offline || pnpm install --frozen-lockfile
COPY . .
ENV DOCKER_BUILD=true
RUN pnpm run build

# ---- 第 3 阶段：生成运行时镜像 ----
FROM node:20-alpine AS runner

# 1. 安装 CA 证书和下载 cloudflared 所需的工具
RUN apk add --no-cache ca-certificates curl bash \
    && rm -rf /var/cache/apk/*

# 2. 下载并安装适合 Alpine (libc) 的 cloudflared 二进制文件
# 注意：Alpine 需要特定的 musl 或链接良好的版本，官方提供的 linux-amd64 通常可以运行
RUN curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared \
    && chmod +x /usr/local/bin/cloudflared

RUN addgroup -g 1001 -S nodejs && adduser -u 1001 -S nextjs -G nodejs

WORKDIR /app

RUN mkdir -p /app/video-cache && chown -R nextjs:nodejs /app/video-cache
ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0
ENV PORT=3000
ENV DOCKER_BUILD=true

COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/scripts ./scripts
COPY --from=builder --chown=nextjs:nodejs /app/start.js ./start.js
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# 3. 创建一个组合启动脚本
# 我们需要同时启动 Node 和 Cloudflared。使用 bash 脚本来管理两个进程。
RUN echo '#!/bin/bash\n\
# 启动 Node.js 应用并放入后台\n\
node start.js &\n\
\n\
# 启动 Cloudflare Tunnel\n\
# CLOUDFLARE_TOKEN 需要在环境变量中设置\n\
if [ -z "$CLOUDFLARE_TOKEN" ]; then\n\
  echo "Error: CLOUDFLARE_TOKEN is not set."\n\
  exit 1\n\
fi\n\
\n\
echo "Starting Cloudflare Tunnel..."\n\
cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TOKEN"\n\
' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh && chown nextjs:nodejs /app/entrypoint.sh

USER nextjs

EXPOSE 3000

# 使用新的脚本启动
CMD ["/app/entrypoint.sh"]
