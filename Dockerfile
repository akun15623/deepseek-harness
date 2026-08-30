# DeepSeek Harness — minimal Dockerfile (official source build)
#
# Builds the upstream monorepo (pnpm workspace) and ships the Web UI server.
# Upstream CLI rejects `--host 0.0.0.0` for safety; we bind to 127.0.0.1
# inside the container and let the sidecar Caddy reverse-proxy handle the
# LAN-facing HTTPS endpoint.

FROM mcr.microsoft.com/devcontainers/javascript-node:22-bookworm AS build

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@11.7.0 --activate
RUN pnpm config set registry https://registry.npmmirror.com

# Manifests first for layer caching.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY tsconfig.json tsconfig.base.json tsconfig.host.json tsconfig.client.json tsconfig.base.client.json ./
COPY tsdown.config.ts ./
COPY patches ./patches
COPY apps/ apps/
COPY packages/ packages/
COPY vendor/ vendor/
COPY native/ native/
COPY examples/ examples/
COPY scripts/ scripts/
# scripts/build.ts embeds the source commit via `git rev-parse HEAD`.
COPY .git .git
COPY python/ python/
COPY website/ website/

RUN pnpm install --frozen-lockfile
RUN pnpm run build

# Install the community plugin that relaxes the settings/credentials plane
# from loopback-only to trustedHosts (see upstream discussion #1733). Use
# `pnpm exec` so the plugin process inherits a PATH that contains pnpm;
# `node apps/cli/lib/bin.js plugin ...` shells out to pnpm itself, and Docker
# RUNs are isolated shells so pnpm is not on PATH for plain `node` invocations.
# DSH_HOME=/app/.dsh keeps the profile inside the build tree so the runtime
# stage's `COPY --from=build /app /app` brings it along.
ENV DSH_HOME=/app/.dsh
RUN pnpm exec node apps/cli/lib/bin.js plugin --profile web add dsh-lan-access

# ---------------------------------------------------------------------------

FROM mcr.microsoft.com/devcontainers/javascript-node:22-bookworm AS runtime

WORKDIR /app
ENV NODE_ENV=production
# pnpm for runtime plugin installs (`dsh plugin --profile web add <pkg>`
# shells out to pnpm; the isolated RUN/exec shells have no pnpm otherwise).
RUN corepack enable && corepack prepare pnpm@11.7.0 --activate
COPY --from=build /app /app
# FORK: point DSH_HOME at the named volume (`dsh-home` is mounted at
# /root/.dsh in compose) so plugins installed at runtime — e.g. the
# dsh-market community plugin — survive container rebuilds. The build-stage
# profile (containing dsh-lan-access) is seeded into the image's /root/.dsh;
# a fresh empty named volume is auto-populated from it on first mount.
RUN mkdir -p /root/.dsh && cp -a /app/.dsh/. /root/.dsh/
ENV DSH_HOME=/root/.dsh

EXPOSE 3080
# Upstream binds 127.0.0.1:3080 by default — fine for a Caddy sidecar.
CMD ["node", "apps/cli/lib/bin.js", "web", "--no-open"]
