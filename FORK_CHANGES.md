# Fork 改动记录（FORK_CHANGES）

本文件记录 `deepseek-harness` fork（`github.com/akun15623/deepseek-harness`）相对上游
（`github.com/deepseek-ai/deepseek-harness`）的全部本地改动，以及低成本同步上游的流程。

## 1. 仓库与基线

| 项 | 值 |
|---|---|
| 上游官方仓库 | `git@github.com:deepseek-ai/deepseek-harness.git` |
| fork 仓库（origin） | `git@github.com:akun15623/deepseek-harness.git` |
| 基线提交（fork 起点） | `b150a551b8` — Merge pull request #2908 (release/dsh-0.1.1-rc.2) |
| 本地分支策略 | 双分支：`master` = 上游纯净镜像（可 ff 同步）；全部改动提交在 `custom` 分支（见 §5） |

> 本项目采用「双分支」策略：`master` 保持上游纯净镜像（仅上游源码，用于 `ff` 同步），
> 全部本地改动（Docker 部署文件 + settings plane 源码 patch + 共享密钥访问门禁）提交在
> `custom` 分支。**部署、开发、重新构建都在 `custom` 分支上进行**。同步上游流程见 §5。

## 2. 目标与设计原则

**目标**：让 DeepSeek Harness 的 Web UI 能在局域网通过 `http://<NAS-IP>:3080` 完整可用，
包括上游刻意锁定为「仅本机回环」的 **设置页（Models / Providers / 凭据）**。

**设计原则**：

1. **追加文件为主、少量源码 patch**：Docker 部署全部落在新增文件里；为满足「内网 HTTP
   直连即可配置模型/设置页」而改动 **3 处源码**（见 §3），每处都加 `// FORK:` 注释标记，
   便于上游同步时定位与重叠加。
2. **随机 UUID 不依赖 secure context**：上游 Web UI 多处直接用 `crypto.randomUUID()`，
   该 API 只在 secure context（https 或 localhost）下存在；改绑 `0.0.0.0` 后经
   `http://<IP>:3080` 访问是 insecure context，会报 `crypto.randomUUID is not a function`。
   本 fork **不改这三处源码**，改为在 Dockerfile 构建阶段安装社区插件
   [`dsh-lan-access`](https://www.npmjs.com/package/dsh-lan-access)，由其注入 polyfill。
3. **显式记录安全权衡**：上游把 `settings.*`/`credentials.*` 设为 loopback-only，是刻意的
   安全边界（Web 载体无认证层，放开等于局域网内任何设备都能改 API Key/模型配置）。
   本 fork 为满足部署需要把 settings/credentials 平面从 loopback-only 放开到
   `trustedHosts`。**这是 DNS-rebinding 栅栏，不是认证**；仅限可信内网使用。
   本 fork **不自带认证层**——门禁由上游未来原生多用户账户承载，不复活本 fork 历史版本。

## 3. 逐文件改动清单

### 源码改动（为 settings 平面 LAN 可用，共 3 处）

上游把 settings/credentials 平面设计成 loopback-only（后端）+ 前端按地址栏 hostname 判定
是否回环（`connection.isLoopback`）。两者叠加导致 LAN 访问时设置页报
「settings are unavailable in this browser」或 `/api/settings.describe` 返回 403。
本 fork 让「内网 `http://<IP>:3080` 直连」也能配置模型/设置页：

| 文件 | 改动 | 目的 |
|---|---|---|
| `packages/client/connection/src/index.ts` | 特权方法（`settings.*`/`credentials.*`/`host.pickDirectory`/`llm.discoverModels`）的 trust fence 从 `isTrustedApiRequest(request, [])`（空信任表=仅 loopback）改为 `isTrustedApiRequest(request, trustedHosts)` | 后端放行 settings/credentials 平面，跟随 `--trusted-host` 配置，LAN 访问不再 403 |
| `packages/client/ui-settings/src/client/index.ts` | `SettingsDescribeMirror` 的 persistence 从 `connection.isLoopback ? 'host' : 'memory'` 改为恒 `'host'` | 前端 settings mirror 主动发 `settings.describe`，不再因「非 loopback 地址栏」禁用 |
| `packages/client/ui-settings/src/client/settings-scope.ts` | `SettingsScopeController` 的 persistence 同上改为恒 `'host'` | 同上，作用于 Models/Providers 等具体 scope |

### Docker 部署文件（新增）

| 文件 | 状态 | 说明 |
|---|---|---|
| `Dockerfile` | 新增 | 多阶段构建：build 阶段 `pnpm install --frozen-lockfile` + `pnpm run build`，再安装社区插件 `dsh-lan-access`（randomUUID polyfill）；runtime 阶段 `corepack prepare pnpm@11.7.0`（runtime 装插件用）+ `COPY --from=build /app /app` + `cp -a /app/.dsh/. /root/.dsh/` 把构建期 profile 拷贝到卷路径 + `ENV DSH_HOME=/root/.dsh`（指向 compose 挂的命名卷 `dsh-home`，runtime 装的插件持久化）。registry 用 `registry.npmmirror.com`。基础镜像 `mcr.microsoft.com/devcontainers/javascript-node:22-bookworm`。 |
| `docker-compose.yml` | 新增 | 三服务：`dsh`（绑 127.0.0.1:3080，`--trusted-host` 传 LAN IP + 公网 IP + 域名，来自 `.env` gitignored；`DSHM_NPM_MIRROR=https://registry.npmmirror.com` 让 dsh-market 把 npm 包安装路由到 npmmirror——其默认 china region 用的是 `mirrors.cloud.tencent.com/npm`，多数网络下慢；`DSH_GITHUB_TOKEN` 来自 `.env`，供 dsh-market 的 Gist 备份读取，留空走 `gh auth token` 兜底；`SETUP_KEY` 来自 `.env`，dsh-passwords 插件的 JWT 派生种子）、`cert_init`（一次性容器，自签证书 SAN=`DNS:<域名>,IP:<LAN>,IP:<公网>`，alpine 源切 aliyun）、`caddy`（宿主 `3080:443` 反代 TLS，无宿主 80 映射——被 NAS 系统占用）。healthcheck 判定放宽为「仅 5xx/无响应算不健康」——401（密码门禁拦未认证探针）与 404（插件移除后的端点）是预期形态。**2026-08-27 起全部持久化走 NAS bind 目录**（原 4 个命名卷见 §6「fnOS 删卷事件」）：`/vol1/1000/appData/deepseek-harness/.dsh→/root/.dsh`、`.../_data→/root/data`、`.../caddy/data→caddy:/data`、`.../caddy/config→caddy:/config`；dsh 侧另有 fnOS 面板手工加入并已固化的三项挂载（`agent-common→/root/agent-common`、`agent-common-env/ssh-key(agent-hermes)→/root/.ssh`、`docker.sock→/var/run/docker.sock`）。**宿主路径统一从 `.env` 的 `HOST_APP_DATA`（NAS 视角数据根，默认 `/vol1/1000/appData`）读取**，迁移宿主只改 `.env` 一处；`docker.sock` 为系统固定路径不参数化。 |
| `.dockerignore` | 新增 | 排除 `node_modules`/构建产物，但保留 `.git`（build 阶段 `git rev-parse HEAD` 嵌入源码 commit）。 |

## 4. 安全权衡（重要）

- 本 fork 放开了 settings/credentials 平面到 `trustedHosts`；`trustedHosts` 只是
  DNS-rebinding 栅栏（防恶意网页伪造 Host），**本身不是认证**。
- **本 fork 没有自带认证层**——源码层面只放开了 settings/credentials 平面的
  trustedHosts 栅栏，未提供登录门禁、token 验证或任何身份识别层。任何能访问
  `https://<NAS-IP>:3080` 的设备都能读/改 models/providers/credentials。
- 当前部署的安全模型靠**外层三件套**叠加，缺一不可：
  1. **Caddy TLS**（自签证书 + 端口 3080→443 反代，浏览器可识别为 HTTPS）
  2. **自签 CA 导入用户设备**——导出 `dsh-cert.pem` 后在每台访问设备的系统根证书库
     信任（Windows「受信任的根证书颁发机构」/ macOS Keychain「始终信任」/ Android CA
     install / iOS 描述文件 + 完全信任）；否则浏览器一直拒绝连接，等同于部署离线
  3. **DSH_TRUSTED_HOST_DOMAIN/LAN/PUBLIC 严格收敛**——只放行你实际访问的 host/IP；
     `--trusted-host` 参数直接进 trust fence，对未列 host 仍 403
- 上游官方 issue/discussion（如 #1733）明确 settings 平面 loopback-only 是刻意设计；本 fork
  是有意的本地取舍。若上游未来加入原生多用户账户或真正的认证层，**应直接迁移到上游方案**，
  而不是复活 fork 旧版本地门禁路径。
- 自签证书 365 天过期——届时 `cert_init` 一次性容器不重跑，需要人工续期（`docker compose run
  --rm cert_init` 然后清 caddy_data 旧 cert 再 `docker restart deepseek-harness-caddy`）。

## 5. 同步上游流程

1. 切到 `master`，`git fetch upstream && git merge --ff-only upstream/master`（纯净镜像）。
2. 切回 `custom`，`git rebase master`（本地改动重叠加到最新上游）。
3. 处理冲突时：优先按上游最新语义重写本 fork 的 `// FORK:` 处；若上游已原生支持某能力
   （例如未来加入真正的认证层），应删除对应 fork 改动，而不是保留。
4. 改完 `git push origin custom --force-with-lease`。

## 6. 构建注意事项（实测坑）

- **构建需 `.git`**：`scripts/build.ts` 通过 `git rev-parse HEAD` 嵌入源码 commit 到前端
  产物（`DSH_CLIENT_COMMIT_HASH`）。`.dockerignore` 不能排除 `.git`，Dockerfile 需
  `COPY .git .git`。
- **dsh-lan-access 安装需 `pnpm exec`**：`node apps/cli/lib/bin.js plugin ...` 会子进程
  spawn `pnpm`，而 Docker 每个 RUN 是独立 shell、`pnpm` 不在 PATH；必须用
  `pnpm exec node apps/cli/lib/bin.js plugin --profile web add dsh-lan-access`。
- **`DSH_HOME=/app/.dsh`**：build 阶段安装插件会写 profile 到 `~/.dsh`；设 `DSH_HOME=/app/.dsh`
  让 profile 落在构建树内，runtime 的 `COPY --from=build /app /app` 才能带过去，runtime
  同样设 `ENV DSH_HOME=/app/.dsh`。
- **trustedHosts 只认 CLI 参数或 cordis.yml**：官方代码**不读** `DSH_TRUSTED_HOSTS` 环境变量，
  必须用 `dsh web --trusted-host <IP>` 或 cordis.yml `connection.trustedHosts`。
- **bind mount 路径（2026-08-27 起为唯一持久化形态）**：compose 在 Agent 容器、daemon 在 NAS，
  bind 源必须是 **NAS 侧绝对路径**（`/vol1/1000/appData/...`）——Agent 容器内的路径 daemon 不可见。
  compose 中统一写成 `${HOST_APP_DATA}/...`，值在 `.env`（`HOST_APP_DATA=/vol1/1000/appData`）。
  命名卷（`dsh_workspace`/`dsh-home`/`caddy_data`/`caddy_config`）已被 fnOS 删卷事件淘汰（见下），
  注意 **bind mount 会遮住镜像内 `/root/.dsh` 的 seed 内容**（命名卷首次挂载会自动从镜像拷贝，
  bind 目录为空时直接以空目录覆盖镜像层）——空目录首次启动后需重装 runtime 插件。
- **fnOS 删卷事件（2026-08-27）**：用户在 fnOS 面板把外挂数据卷换成宿主目录时，`/vol3/docker/volumes/`
  下 `deepseek-harness_dsh-home` 与 `deepseek-harness_dsh_workspace` 的数据目录被删除（caddy 两卷
  幸存）。后果：dsh-lan-access + dshmarket 插件、web profile 全部丢失需重装；workspace 对话历史丢失。
  恢复动作：`docker exec deepseek-harness-dsh sh -c 'NPM_CONFIG_REGISTRY=https://registry.npmmirror.com
  node /app/apps/cli/lib/bin.js plugin --profile web add dsh-lan-access'`（dshmarket 同理），
  然后 `docker restart deepseek-harness-dsh`。教训：**面板操作会绕过 compose 视角直接动卷，
  切换持久化形态前先备份数据**（caddy 证书当时靠 `docker cp` 从运行中容器抢救成功）。
- **settings.yaml / .credentials.yaml 是启动关键文件（2026-08-27 事故）**：dsh-settings-file
  支持外部编辑热发布（chokidar watch 100ms），但**文件损坏 = dsh 启动失败进重启循环**
  （实测：追加内容时原文件末尾无换行导致粘行 `BLOCK_AS_IMPLICIT_KEY` + 两轮编辑叠加
  `DUPLICATE_KEY` → 容器 Restarting(1)）。手工编辑纪律：**改前 `cp` 备份、追加前确认
  末尾有换行、改后必须过 YAML 校验再动容器**（临时容器 `node -e "require('yaml').parse(...)"`
  或直接看重启后日志）。`.credentials.yaml` 另有权限要求：必须是 600（owner-only），
  UI 写入后若权限变宽（如 705）credentials-local 拒绝启动，`chmod 600` 修复。
- **agent 侧 /tmp 路径复踩注记**：想给 NAS 上的临时容器挂脚本/文件时，`-v /tmp/xxx` 用的是
  agent 容器内路径，**daemon（NAS）不可见**——daemon 会静默创建同名空目录，`sh` 执行目录
  静默 exit 0，毫无报错（2026-08-27 复踩一次，修复脚本看似成功实际未执行）。可靠做法只有
  两种：`docker cp` 送进容器再执行；或 `docker run --rm -i ... sh -s <<EOF` 走 stdin。
- **compose 2.40.3 重建容器不注册服务名别名**：fnOS 面板/新版 compose 重建 `dsh` 容器后，网络里
  只有容器名 `deepseek-harness-dsh`，服务别名 `dsh` 缺失（`docker inspect` 里 `Aliases: []`），
  Caddy 用 `reverse_proxy dsh:3080` 报 `lookup dsh: no such host` → 502。**规避：Caddyfile upstream
  一律写容器名**（`reverse_proxy deepseek-harness-dsh:3080`，容器名永远注册）。
- **构建耗时/内存**：全量 `pnpm install` + `pnpm run build` 首次较慢（约 7 分钟），构建阶段
  需约 8GB+ 可用内存。
- **pnpm store 跨设备陷阱**：pnpm 10+ 在「workspace 与默认 store（`~/.local/share/pnpm/store`）
  跨设备」时会自动改用 `<DSH_HOME>/.pnpm-store`（保证硬链接同盘）。Docker 命名卷是独立文件系统，
  所以 runtime DSH_HOME=/root/.dsh 时 pnpm 期望 store 在 `/root/.dsh/.pnpm-store`；而构建期
  profile 在镜像层（与 `~/.local/share` 同盘），装的 node_modules 链自默认 store，会触发
  `ERR_PNPM_UNEXPECTED_STORE`。**首次在卷内 runtime 装插件前必须先在卷里 `pnpm install`
  一次重链**，命令：
  ```sh
  cd /root/.dsh/profiles/web && rm -rf node_modules && pnpm install
  ```
  之后 plugin add 走新 store，不冲突。registry 可设 `NPM_CONFIG_REGISTRY=https://registry.npmmirror.com`。
- **pnpm mirror 选择（`DSHM_NPM_MIRROR`）**：dsh-market 启动时探测网络，选
  `global`（走 `https://registry.npmjs.org`）或 `china`（写死走 `https://mirrors.cloud.tencent.com/npm`）
  二选一，结果持久化到 `/root/.dsh/profiles/web/.dsh-market/state.json`。**腾讯云镜像
  对很多网络慢甚至访问不到**（容器实测 metadata 0.3s 看似 OK，但实际 pnpm add 时仍回源 npmjs.org
  下载 tarball，9 KiB/s 卡死）。`dshmarket/lib/regions.js` 的 `routesFor(region, env)` 显式
  接受 `DSHM_NPM_MIRROR` 环境变量覆盖任意 region 的 npm mirror；`dsh-cli.js` 会把它注入到
  spawn 的 pnpm 子进程 `npm_config_registry`。**compose 里加一行即可**：
  ```yaml
  environment:
    DSHM_NPM_MIRROR: "https://registry.npmmirror.com"
  ```
  `docker compose up -d dsh` 后下次装插件走 npmmirror（实测 metadata 0.1s、tarball 数 MB/s）。
  不需要重建镜像。同类还有 `DSHM_GITHUB_PROXY`（覆盖 china region 的 GitHub 代理 `gh-proxy.com`）。
- **runtime 装插件（dshmarket）**：`dsh plugin --profile web add dshmarket` 写卷内 profile
  + pnpm 装包；装完必须 `docker restart deepseek-harness-dsh` 才会被 cordis 加载（README
  明示）。安装完成后用户打开 https://dsh.akun15623.eu.cc:3080 → Settings → Plugin Market
  即可浏览/一键装社区插件。

## 7. 当前部署插件清单

`/root/.dsh/profiles/web/package.json`（NAS bind 目录 `/vol1/1000/appData/deepseek-harness/.dsh`，
容器重建不丢；2026-08-27 fnOS 删卷后重装，版本未变）：

| 插件 | 来源 | 说明 |
|---|---|---|
| `dsh-lan-access@^0.1.3` | 构建期装入镜像（bind 目录为空时首次启动后需重装） | 兼容层（randomUUID polyfill + 原 0.0.0.0 绑定），HTTPS 域名 + Caddy 反代后冗余但保留以防回退 |
| `dshmarket@^1.31.1` | runtime 装入 bind 目录 | 官方社区插件市场：Settings → Plugin Market 标签，浏览/一键装 1500+ 社区插件、主题、备份/恢复、版本更新诊断。GitHub https://github.com/dsh-market/dsh-market（npm `dshmarket`）。 |
| `dsh-passwords@^2.6.3` | runtime 装入 bind 目录（插件市场） | 多租户密码网关（**独立网关架构**：自己监听端口转发 dsh，非进程内中间件）。`.env` 的 `SETUP_KEY`（JWT 派生种子，`openssl rand -hex 32`）缺省即拒载；**compose 注入 `MCP_GATEWAY_AUTO_TLS=0` + `MCP_GATEWAY_PORT=8080` 以明文网关运行**——其自动 HTTPS（Let's Encrypt）在本拓扑不可用（宿主 80/443 被 NAS 占、无 ACME 入口，错误码 30 拒启），TLS 由外层 Caddy 终止，Caddyfile upstream 已切 `deepseek-harness-dsh:8080`（直连 3080 会绕过门禁）。`MCP_GATEWAY_PUBLIC_HOST=dsh.akun15623.eu.cc:3080` 防 Host 反射。未认证访问 302 → `/gateway/login`，首次访问用 SETUP_KEY 引导创建主用户。 |
| `dsh-auth-gate@^0.9.1` | 已卸载（2026-08-27） | 轻量认证门禁，与 dsh-passwords 功能重叠（两者同装时 gate 拦 401 而 passwords 未激活，处于半激活不一致态），保留 passwords 卸载本插件。 |
