# Deployment Record — DevSpace MCP on Linux + Docker + Cloudflare Tunnel

> 🌐 **Language / 语言**: [English](#english) · [简体中文](#简体中文)

---

## English

This document records the **actual** deployment of this stack on a Linux host
(WSL2 Ubuntu in this case — the steps are identical on any Linux with Docker),
including every pitfall hit and how it was resolved.

- **Date**: 2026-08-20
- **Host**: WSL2 Ubuntu, Docker 28.3.3, cloudflared 2026.8.2
- **Result**: fully working end-to-end, verified over public HTTPS

### 1. Goal & architecture

Deploy the self-hosted [DevSpace](https://github.com/Waishnav/devspace) MCP server
("turn ChatGPT into Codex") so that ChatGPT/Codex can reach it over HTTPS on our own
domain, **without opening any public port**.

```
ChatGPT / Codex
      |
      |  https://devspace.<your-domain>/mcp
      v
Cloudflare Tunnel (cloudflared, outbound-only)
      |
      |  http://devspace:7676   (internal Docker network)
      v
DevSpace container  (MCP server, OAuth owner-token auth)
      |
      |  ./workspace  ->  /workspace
      v
Your local code (Linux host)
```

Hard constraints:

- No public ports — the tunnel connects *outbound* to Cloudflare's edge.
- Container auto-restart (`restart: unless-stopped`).
- Local code directory volume-mapped into the container.
- Out of scope: modifying DevSpace source, building an MCP client, Cloudflare Access
  advanced auth, multi-user permissions.

### 2. Prerequisites

- Any Linux with Docker + Docker Compose v2 (WSL2 Ubuntu, Debian, Ubuntu, …)
- A Cloudflare account with a domain you control (ours: `gongshl.top`, already
  proxied/orange-cloud on Cloudflare)
- `cloudflared` CLI on the host (for the one-time tunnel setup)
- Node.js is **not** needed on the host — it lives inside the image

### 3. Step-by-step

#### 3.1 Configure `.env`

```bash
cd devspace-stack
cp .env.example .env
```

| Variable | Value |
| --- | --- |
| `DEVSPACE_OAUTH_OWNER_TOKEN` | Long random secret (≥16 chars): `openssl rand -base64 32`. This is the **Owner password** you enter to approve MCP clients. |
| `DEVSPACE_PUBLIC_BASE_URL` | Your tunnel origin **without** `/mcp`, e.g. `https://devspace.gongshl.top` |
| `CLOUDFLARED_UID` / `CLOUDFLARED_GID` | Your host UID:GID (`id -u` / `id -g`) — the user that owns `credentials.json` |
| `APT_MIRROR` / `NPM_REGISTRY` / `BUILD_FROM_SOURCE` | Optional build tuning, all unset by default (official sources). Set e.g. `APT_MIRROR=http://mirrors.tuna.tsinghua.edu.cn` / `NPM_REGISTRY=https://registry.npmmirror.com` if downloads crawl, or `BUILD_FROM_SOURCE=true` to compile native modules locally instead of fetching prebuilt binaries from GitHub. |

#### 3.2 Build the DevSpace image

```bash
docker compose build devspace
```

The image is multi-stage: a build stage installs `@waishnav/devspace` globally (with
`python3`/`make`/`g++` for the native `better-sqlite3` module), and a slim runtime
stage copies only the installed package, runs as the non-root `node` user, and defines
a `/healthz` healthcheck.

> **Pitfall 1 — slow downloads.** On a network where Docker Hub / apt / npm are slow,
> build through a host proxy:
>
> ```bash
> docker build --network host \
>   --build-arg HTTP_PROXY=http://127.0.0.1:7897 \
>   --build-arg http_proxy=http://127.0.0.1:7897 \
>   --build-arg HTTPS_PROXY=http://127.0.0.1:7897 \
>   --build-arg https_proxy=http://127.0.0.1:7897 \
>   --build-arg NO_PROXY=127.0.0.1,localhost \
>   --build-arg no_proxy=127.0.0.1,localhost \
>   -t devspace-mcp:latest .
> ```
>
> This took the build from ~6 KB/s (an hour+) to ~800 KB/s.

> **Pitfall 2 — `groupadd: GID '1000' already exists`.** The
> `node:22-bookworm-slim` image already ships a `node` user with UID/GID 1000. Don't
> create a new user — reuse the existing `node` user (`HOME=/home/node`, `USER node`).

#### 3.3 Create the Cloudflare Tunnel (one-time)

Run on the host:

```bash
./cloudflared/setup-tunnel.sh devspace.gongshl.top
```

This:
1. Logs in to Cloudflare (opens a browser) — first time only.
2. Creates a tunnel named `devspace`.
3. Routes `devspace.gongshl.top` → the tunnel (DNS CNAME).
4. Copies the tunnel credentials to `cloudflared/credentials.json`.
5. Generates `cloudflared/config.yml` from `config.yml.example`.

> **Pitfall 3 — `cloudflared tunnel routing` / `tunnel token` no longer exist.**
> cloudflared **2026.x removed** the `tunnel routing` and `tunnel token` CLI
> subcommands. The old "add routing + print token" flow is gone. The supported way now
> is **named-tunnel mode from a config file**:
>
> - ingress (hostname → service) lives in `cloudflared/config.yml`
> - credentials (TunnelID + TunnelSecret) live in `cloudflared/credentials.json`
> - the container runs `cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`
>
> No token, no dashboard.

#### 3.4 Start the stack

```bash
docker compose up -d
docker compose ps
# devspace      ...   healthy
# cloudflared   ...   running
```

> **Pitfall 4 — `permission denied` reading `credentials.json`.** The
> `cloudflare/cloudflared` image runs as UID **65532** by default, but
> `credentials.json` is owned by your host user (e.g. UID 1000) with mode 600. The
> container can't read it. Fix: run the cloudflared container as the file's owner —
> set `CLOUDFLARED_UID`/`CLOUDFLARED_GID` in `.env` (the compose file maps them to
> `user: "${CLOUDFLARED_UID}:${CLOUDFLARED_GID}"`).
>
> (Note: `chown`-ing the file to 65532 from a non-root host user is not possible, so
> matching the container's user to the file's owner is the clean fix.)

### 4. Verification

All of these were run against the **public** HTTPS endpoint
(`https://devspace.gongshl.top`), i.e. through the real tunnel:

| Check | Command | Result |
| --- | --- | --- |
| Health (no auth) | `curl -fsS https://devspace.gongshl.top/healthz` | `{"ok":true,"name":"devspace"}` |
| MCP endpoint requires auth | `curl -s -o /dev/null -w '%{http_code}' https://devspace.gongshl.top/mcp` | `401` |
| OAuth discovery | `GET /.well-known/oauth-protected-resource/mcp` + `/.well-known/oauth-authorization-server` | correct `resource`/endpoints |
| Dynamic client registration | `POST /register` | returns `client_id` |
| Authorize (owner token) | `POST /authorize` with `owner_token` | `302` with `code` |
| Token exchange | `POST /token` | `access_token` |
| MCP initialize | `POST /mcp` | `protocolVersion 2025-06-18`, session id |
| tools/list | `POST /mcp` | `open_workspace`, … |
| **open_workspace** | `tools/call open_workspace {path:"/workspace"}` | `workspaceId: ws_…` |
| Workspace mount R/W | write file on host → read in container | visible both ways |
| No public ports | `docker inspect devspace … .NetworkSettings.Ports` | `{"7676/tcp":null}` |

The full OAuth + `open_workspace` flow was exercised with a script: register →
authorize (PKCE S256 + owner token) → token → initialize →
`tools/call open_workspace`.

### 5. Auto-restart & reboot recovery

Both services use `restart: unless-stopped`. Semantics:

- Container **crashes** → Docker restarts it.
- **Docker daemon restarts** (this is what happens on a host reboot) → containers come
  back automatically.
- `docker kill` / `docker stop` (you stopped it on purpose) → **not** restarted. This
  is by design, not a bug.

After a reboot:

```bash
sudo systemctl start docker        # systemd hosts (bare Linux, VMs)
# WSL2: sudo service docker start, or just open a WSL shell
cd devspace-stack
docker compose up -d               # no-op if already running
docker compose ps
curl -fsS https://devspace.gongshl.top/healthz
```

> **Observation (environment quirk, not a config issue).** On this WSL2 Docker setup,
> sending `SIGKILL` to the container's PID 1 (via
> `node -e 'process.kill(1,"SIGKILL")'`) did **not** terminate the process —
> `/proc/1`'s start time stayed unchanged and the container kept running. So a crash
> could not be simulated that way here. The `unless-stopped` policy is confirmed
> present via `docker inspect`; the daemon-restart path is the one that matters for
> reboot recovery and is the standard guarantee of this policy.

### 6. Pitfall summary

| # | Symptom | Cause | Fix |
| --- | --- | --- | --- |
| 1 | Build ~6 KB/s, 1hr+ | Slow network to Docker Hub/apt/npm | Build via host proxy (`--network host` + `HTTP(S)_PROXY` build-args) |
| 2 | `groupadd: GID '1000' already exists` | `node:22-bookworm-slim` already has `node` UID/GID 1000 | Reuse the existing `node` user |
| 3 | `tunnel routing` / `tunnel token`: "no valid argument" | Removed in cloudflared 2026.x | Named-tunnel mode: `config.yml` + `credentials.json` |
| 4 | `permission denied` on `credentials.json` | Image runs as UID 65532; file owned by host UID 1000, mode 600 | `user: "${CLOUDFLARED_UID}:${CLOUDFLARED_GID}"` in compose |
| 5 | `docker kill` doesn't auto-restart | `unless-stopped` skips user-initiated stops | Expected behavior; crash/daemon-restart still auto-restart |

### 7. Connecting an MCP client

Point your client at:

```
https://devspace.gongshl.top/mcp
```

On first connect, DevSpace shows an approval page — enter the **Owner password**
(`DEVSPACE_OAUTH_OWNER_TOKEN`). After that the client can open a project under
`/workspace` and read/edit/run code.

```json
{
  "mcpServers": {
    "devspace": {
      "url": "https://devspace.gongshl.top/mcp"
    }
  }
}
```

### 8. Teardown

```bash
docker compose down          # stop + remove containers (keeps volumes)
docker compose down -v       # also remove state/worktree volumes
# remove the tunnel + DNS record:
cloudflared tunnel delete devspace
```

---

## 简体中文

本文档记录了该栈在一台 Linux 主机上的**真实**部署过程（本次是 WSL2 Ubuntu ——
在任意带 Docker 的 Linux 上步骤完全相同），包括踩过的每个坑及其解决方法。

- **日期**：2026-08-20
- **主机**：WSL2 Ubuntu，Docker 28.3.3，cloudflared 2026.8.2
- **结果**：全链路打通，已通过公网 HTTPS 验证

### 1. 目标与架构

部署自托管的 [DevSpace](https://github.com/Waishnav/devspace) MCP 服务器（"把
ChatGPT 变成 Codex"），让 ChatGPT/Codex 能通过我们自己的域名以 HTTPS 访问它，
**且不开放任何公网端口**。

```
ChatGPT / Codex
      |
      |  https://devspace.<你的域名>/mcp
      v
Cloudflare Tunnel (cloudflared, 仅出站)
      |
      |  http://devspace:7676   (Docker 内部网络)
      v
DevSpace 容器  (MCP 服务器, OAuth owner-token 鉴权)
      |
      |  ./workspace  ->  /workspace
      v
你的本地代码 (Linux 主机)
```

硬性约束：

- 不开放公网端口 —— 隧道是*出站*连接到 Cloudflare 边缘。
- 容器自动重启（`restart: unless-stopped`）。
- 本地代码目录以卷映射进容器。
- 范围之外：修改 DevSpace 源码、开发 MCP 客户端、Cloudflare Access 高级鉴权、
  多用户权限管理。

### 2. 前置条件

- 任意带 Docker + Docker Compose v2 的 Linux（WSL2 Ubuntu、Debian、Ubuntu 等）
- 一个 Cloudflare 账号和一个你控制的域名（我们用的是 `gongshl.top`，已在
  Cloudflare 上开启代理/橙色云）
- 主机上安装 `cloudflared` CLI（用于一次性隧道配置）
- 主机**不需要** Node.js —— 它在镜像里

### 3. 部署步骤

#### 3.1 配置 `.env`

```bash
cd devspace-stack
cp .env.example .env
```

| 变量 | 值 |
| --- | --- |
| `DEVSPACE_OAUTH_OWNER_TOKEN` | 长随机密钥（≥16 字符）：`openssl rand -base64 32`。这是你批准 MCP 客户端时输入的 **Owner 密码**。 |
| `DEVSPACE_PUBLIC_BASE_URL` | 隧道公网源地址，**不带** `/mcp`，例如 `https://devspace.gongshl.top` |
| `CLOUDFLARED_UID` / `CLOUDFLARED_GID` | 你的主机 UID:GID（`id -u` / `id -g`）—— 即 `credentials.json` 的属主用户 |
| `APT_MIRROR` / `NPM_REGISTRY` / `BUILD_FROM_SOURCE` | 可选构建调优，默认全部不设（走官方源）。官方源下载慢时可设 `APT_MIRROR=http://mirrors.tuna.tsinghua.edu.cn` / `NPM_REGISTRY=https://registry.npmmirror.com` 加速，或设 `BUILD_FROM_SOURCE=true` 本地编译原生模块而非下载 GitHub 预编译包。 |

#### 3.2 构建 DevSpace 镜像

```bash
docker compose build devspace
```

镜像是多阶段的：构建阶段全局安装 `@waishnav/devspace`（带 `python3`/`make`/`g++`
用于原生模块 `better-sqlite3`），精简的运行阶段只拷贝安装好的包，以非 root 的
`node` 用户运行，并定义了 `/healthz` 健康检查。

> **坑 1 —— 下载慢。** 在 Docker Hub / apt / npm 慢的网络下，走主机代理构建：
>
> ```bash
> docker build --network host \
>   --build-arg HTTP_PROXY=http://127.0.0.1:7897 \
>   --build-arg http_proxy=http://127.0.0.1:7897 \
>   --build-arg HTTPS_PROXY=http://127.0.0.1:7897 \
>   --build-arg https_proxy=http://127.0.0.1:7897 \
>   --build-arg NO_PROXY=127.0.0.1,localhost \
>   --build-arg no_proxy=127.0.0.1,localhost \
>   -t devspace-mcp:latest .
> ```
>
> 这能把构建速度从 ~6 KB/s（一个多小时）提到 ~800 KB/s。

> **坑 2 —— `groupadd: GID '1000' already exists`。** `node:22-bookworm-slim`
> 镜像自带 UID/GID 1000 的 `node` 用户。不要新建用户 —— 直接复用现有的 `node`
> 用户（`HOME=/home/node`，`USER node`）。

#### 3.3 创建 Cloudflare 隧道（一次性）

在主机上运行：

```bash
./cloudflared/setup-tunnel.sh devspace.gongshl.top
```

它会：
1. 登录 Cloudflare（打开浏览器）—— 仅首次。
2. 创建名为 `devspace` 的隧道。
3. 把 `devspace.gongshl.top` 路由到隧道（DNS CNAME）。
4. 把隧道凭证复制到 `cloudflared/credentials.json`。
5. 从 `config.yml.example` 生成 `cloudflared/config.yml`。

> **坑 3 —— `cloudflared tunnel routing` / `tunnel token` 已不存在。**
> cloudflared **2026.x 移除了** `tunnel routing` 和 `tunnel token` 子命令，旧的
> "加路由 + 打印 token"流程没了。现在支持的方式是**基于配置文件的 named-tunnel
> 模式**：
>
> - ingress（域名 → 服务）写在 `cloudflared/config.yml`
> - 凭证（TunnelID + TunnelSecret）在 `cloudflared/credentials.json`
> - 容器运行 `cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`
>
> 不需要 token，不需要 dashboard。

#### 3.4 启动栈

```bash
docker compose up -d
docker compose ps
# devspace      ...   healthy
# cloudflared   ...   running
```

> **坑 4 —— 读 `credentials.json` 报 `permission denied`。**
> `cloudflare/cloudflared` 镜像默认以 UID **65532** 运行，但 `credentials.json`
> 属主是你的主机用户（如 UID 1000）且权限 600，容器读不了。解决：让 cloudflared
> 容器以文件属主身份运行 —— 在 `.env` 里设置 `CLOUDFLARED_UID`/`CLOUDFLARED_GID`
> （compose 文件把它们映射到 `user: "${CLOUDFLARED_UID}:${CLOUDFLARED_GID}"`）。
>
> （注：非 root 主机用户无法把文件 `chown` 成 65532，所以让容器用户与文件属主
> 一致是干净的解法。）

### 4. 验证

以下全部针对**公网** HTTPS 端点（`https://devspace.gongshl.top`）执行，即走真实
隧道：

| 检查项 | 命令 | 结果 |
| --- | --- | --- |
| 健康检查（无鉴权） | `curl -fsS https://devspace.gongshl.top/healthz` | `{"ok":true,"name":"devspace"}` |
| MCP 端点需鉴权 | `curl -s -o /dev/null -w '%{http_code}' https://devspace.gongshl.top/mcp` | `401` |
| OAuth 发现 | `GET /.well-known/oauth-protected-resource/mcp` + `/.well-known/oauth-authorization-server` | `resource`/端点正确 |
| 动态客户端注册 | `POST /register` | 返回 `client_id` |
| 授权（owner token） | 带 `owner_token` 的 `POST /authorize` | 带 `code` 的 `302` |
| 换 token | `POST /token` | `access_token` |
| MCP initialize | `POST /mcp` | `protocolVersion 2025-06-18`，session id |
| tools/list | `POST /mcp` | `open_workspace` 等 |
| **open_workspace** | `tools/call open_workspace {path:"/workspace"}` | `workspaceId: ws_…` |
| workspace 挂载读写 | 宿主机写文件 → 容器内读 | 双向可见 |
| 无公网端口 | `docker inspect devspace … .NetworkSettings.Ports` | `{"7676/tcp":null}` |

完整 OAuth + `open_workspace` 流程用脚本跑通：注册 → 授权（PKCE S256 + owner
token）→ 换 token → initialize → `tools/call open_workspace`。

### 5. 自动重启与重启恢复

两个服务都用 `restart: unless-stopped`。语义：

- 容器**崩溃** → Docker 自动重启它。
- **Docker 守护进程重启**（主机重启时正是这种情况）→ 容器自动回来。
- `docker kill` / `docker stop`（你主动停的）→ **不会**重启。这是设计如此，不是 bug。

重启后：

```bash
sudo systemctl start docker        # systemd 主机 (物理 Linux、虚拟机)
# WSL2: sudo service docker start, 或直接打开一个 WSL 终端
cd devspace-stack
docker compose up -d               # 已在运行则是空操作
docker compose ps
curl -fsS https://devspace.gongshl.top/healthz
```

> **观察（环境怪癖，非配置问题）。** 在这套 WSL2 Docker 环境里，向容器 PID 1
> 发送 `SIGKILL`（通过 `node -e 'process.kill(1,"SIGKILL")'`）**没有**终止该进程
> —— `/proc/1` 的启动时间没变，容器继续运行。因此无法用这种方式在这里模拟崩溃。
> `unless-stopped` 策略已通过 `docker inspect` 确认存在；守护进程重启这条路径才是
> 重启恢复的关键，也是该策略的标准保证。

### 6. 踩坑汇总

| # | 现象 | 原因 | 解决 |
| --- | --- | --- | --- |
| 1 | 构建 ~6 KB/s，一个多小时 | 到 Docker Hub/apt/npm 网络慢 | 走主机代理构建（`--network host` + `HTTP(S)_PROXY` build-args） |
| 2 | `groupadd: GID '1000' already exists` | `node:22-bookworm-slim` 自带 `node` UID/GID 1000 | 复用现有 `node` 用户 |
| 3 | `tunnel routing` / `tunnel token`："no valid argument" | cloudflared 2026.x 已移除 | named-tunnel 模式：`config.yml` + `credentials.json` |
| 4 | 读 `credentials.json` 报 `permission denied` | 镜像以 UID 65532 运行；文件属主是主机 UID 1000，权限 600 | compose 里 `user: "${CLOUDFLARED_UID}:${CLOUDFLARED_GID}"` |
| 5 | `docker kill` 后不自动重启 | `unless-stopped` 不重启用户主动停止 | 属预期；崩溃/守护进程重启仍会自动重启 |

### 7. 连接 MCP 客户端

把客户端指向：

```
https://devspace.gongshl.top/mcp
```

首次连接时 DevSpace 会显示批准页 —— 输入 **Owner 密码**
（`DEVSPACE_OAUTH_OWNER_TOKEN`）。之后客户端就能打开 `/workspace` 下的项目并
读/写/运行代码。

```json
{
  "mcpServers": {
    "devspace": {
      "url": "https://devspace.gongshl.top/mcp"
    }
  }
}
```

### 8. 拆除

```bash
docker compose down          # 停止并删除容器 (保留卷)
docker compose down -v       # 同时删除 state/worktree 卷
# 删除隧道 + DNS 记录:
cloudflared tunnel delete devspace
```
