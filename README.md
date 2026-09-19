# DevSpace MCP Stack (Linux + Docker + Cloudflare Tunnel)

> 🌐 **Language / 语言**: [English](#english) · [简体中文](#简体中文)

---

## English

Self-hosted [DevSpace](https://github.com/Waishnav/devspace) MCP server, containerized
with Docker Compose and exposed over HTTPS through a **Cloudflare Tunnel** on your own
domain. No public ports are opened — the tunnel connects *outbound* to Cloudflare's edge.

Works on any Linux host: WSL2, bare metal, a VM, or a small server.

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

> 📖 Looking for a real-world deployment walkthrough (including every pitfall and how
> it was fixed)? See [DEPLOYMENT.md](./DEPLOYMENT.md).

### What's in this repo

```
devspace-stack/
├── docker-compose.yml        # devspace + cloudflared services
├── Dockerfile                # DevSpace image (node:22, non-root, healthcheck)
├── .env.example              # template — copy to .env
├── .env                      # your secrets (git-ignored)
├── .gitignore
├── LICENSE                   # MIT
├── THIRD-PARTY.md            # third-party license attribution
├── DEPLOYMENT.md             # bilingual record of a real deployment + pitfalls
├── devspace-config/
│   └── config.json           # non-secret DevSpace config (allowed roots, etc.)
├── cloudflared/
│   ├── setup-tunnel.sh       # one-time Cloudflare tunnel setup helper
│   ├── config.yml.example    # tunnel ingress template (committed)
│   ├── config.yml            # generated per-machine (git-ignored)
│   └── credentials.json      # tunnel credentials (git-ignored, created by setup)
└── workspace/                # your local code, mounted into the container
```

### Prerequisites

- Any Linux with Docker + Docker Compose v2 (WSL2 Ubuntu, Debian, Ubuntu, …)
- A Cloudflare account with a domain you control
- `cloudflared` CLI on the host (for the one-time tunnel setup)
- Node.js is **not** needed on the host — it's inside the image

### 1. Configure

```bash
cd devspace-stack
cp .env.example .env
```

Edit `.env`:

| Variable | Value |
| --- | --- |
| `DEVSPACE_OAUTH_OWNER_TOKEN` | A long random secret (≥16 chars). Generate: `openssl rand -base64 32`. This is the **Owner password** you enter to approve MCP clients. Keep it private. |
| `DEVSPACE_PUBLIC_BASE_URL` | Your tunnel origin **without** `/mcp`, e.g. `https://devspace.example.com` |
| `CLOUDFLARED_UID` / `CLOUDFLARED_GID` | Your host UID:GID (`id -u` / `id -g`) — the user that owns `cloudflared/credentials.json` |
| `APT_MIRROR` / `NPM_REGISTRY` / `BUILD_FROM_SOURCE` | Optional build tuning, all unset by default (official sources). If apt/npm downloads crawl from your network, set e.g. `APT_MIRROR=http://mirrors.tuna.tsinghua.edu.cn` and `NPM_REGISTRY=https://registry.npmmirror.com`; `BUILD_FROM_SOURCE=true` compiles native modules locally instead of fetching prebuilt binaries from GitHub (useful where that download hangs). |

The non-secret DevSpace config lives in `devspace-config/config.json`. The key setting is
`allowedRoots` — the folders DevSpace may open. It's set to `/workspace` (the mounted
directory). Add more roots there if you mount more directories.

The tunnel itself is configured by **files**, not `.env` variables (see step 2):
`cloudflared/config.yml` (ingress) and `cloudflared/credentials.json` (credentials).

### 2. Create the Cloudflare Tunnel (one-time)

Run on the host (pass your own public hostname):

```bash
./cloudflared/setup-tunnel.sh devspace.example.com
```

This will:
1. Log in to Cloudflare (opens a browser) — only the first time
2. Create a tunnel named `devspace`
3. Route your hostname → the tunnel (DNS CNAME)
4. Copy the tunnel credentials into `cloudflared/credentials.json`
5. Generate `cloudflared/config.yml` from `config.yml.example` (filling in your
   tunnel UUID and hostname)

The ingress (which hostname maps to which service) is defined in
`cloudflared/config.yml`. The committed template is
`cloudflared/config.yml.example`; the generated `config.yml` is per-machine and
git-ignored.

> **Why files and not a token?** cloudflared 2026.x removed the `tunnel routing`
> and `tunnel token` CLI subcommands. The supported way to run a named tunnel is
> from a credentials file + a config file that defines the ingress. The container
> runs `cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`.
> No token, no dashboard.

### 3. Start the stack

```bash
docker compose up -d
```

Wait for DevSpace to become healthy:

```bash
docker compose ps
# devspace      ...   healthy
# cloudflared   ...   running
```

### 4. Verify

**Health (no auth):**
```bash
curl -fsS https://devspace.example.com/healthz
# {"ok":true,"name":"devspace"}
```

**MCP endpoint** requires OAuth. Connect your MCP client (ChatGPT / Codex / Claude) to:

```
https://devspace.example.com/mcp
```

On first connect, DevSpace shows an approval page — enter the **Owner password**
(`DEVSPACE_OAUTH_OWNER_TOKEN`). After that, the client can open a project under
`/workspace` and read/edit/run code.

### 5. Connect an MCP client

Add the endpoint to your client's MCP config:

```json
{
  "mcpServers": {
    "devspace": {
      "url": "https://devspace.example.com/mcp"
    }
  }
}
```

For ChatGPT, add it as a custom connector / App pointing at the `/mcp` URL.

### Logs

```bash
docker compose logs -f devspace     # DevSpace server (JSON logs)
docker compose logs -f cloudflared  # tunnel status / reconnects
docker compose logs --tail=100      # both
```

DevSpace logs requests and tool calls by default. To see shell command previews, set
`DEVSPACE_LOG_SHELL_COMMANDS=1` in `config.json` (only if commands contain no secrets).

### Reboot / recovery

Docker containers are set to `restart: unless-stopped`, so they come back automatically
when the Docker daemon starts. After a reboot:

```bash
# 1. Make sure Docker is running
sudo systemctl start docker        # systemd hosts (bare Linux, VMs)
# WSL2: sudo service docker start, or just open a WSL shell

# 2. Bring the stack up (no-op if already running)
cd devspace-stack
docker compose up -d

# 3. Confirm
docker compose ps
curl -fsS https://devspace.example.com/healthz
```

If a container is stuck `restarting`, check its logs:
```bash
docker compose logs --tail=50 devspace
```

Common causes:
- **Port 7676 already in use** on the host — stop the other process.
- **`cloudflared/credentials.json` missing** — re-run `./cloudflared/setup-tunnel.sh <hostname>` to copy it in.
- **Tunnel not routing** — check `cloudflared/config.yml` has the right `hostname:` and `service:`.
- **`better-sqlite3 could not load`** — rebuild the image: `docker compose build --no-cache devspace`.

### Updating DevSpace

Bump `DEVSPACE_VERSION` in the `Dockerfile` (or remove the pin to track latest), then:

```bash
docker compose build devspace
docker compose up -d
```

### Security notes

- **No public ports.** The only internet-facing entry is the Cloudflare Tunnel hostname.
- **OAuth owner-token** protects the MCP endpoint. Anyone with the Owner password can
  approve a client — treat it like a password.
- **`allowedRoots`** is the filesystem allowlist. Keep it narrow (just `/workspace`).
- The shell tool runs commands as the container user. A connected client is effectively
  a trusted coding partner with access to the mounted workspace.
- For extra protection, add **Cloudflare Access** in front of the tunnel hostname
  (out of scope here, but a natural next step).

### Teardown

```bash
docker compose down          # stop + remove containers (keeps volumes)
docker compose down -v       # also remove state/worktree volumes
# remove the tunnel + its DNS record:
cloudflared tunnel delete devspace
```

### License

This repository's code (Dockerfile, compose file, config templates, and setup
scripts) is licensed under the **MIT License** — see [LICENSE](./LICENSE).

This project packages and runs third-party open-source software (DevSpace,
cloudflared, and their dependencies). Their licenses are listed in
[THIRD-PARTY.md](./THIRD-PARTY.md).

---

## 简体中文

自托管 [DevSpace](https://github.com/Waishnav/devspace) MCP 服务器，用 Docker Compose
容器化，通过 **Cloudflare Tunnel** 以自有域名 HTTPS 暴露。不开放任何公网端口 ——
隧道是*出站*连接到 Cloudflare 边缘。

适用于任何 Linux 主机：WSL2、物理机、虚拟机或小服务器均可。

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

> 📖 想看一次真实部署的完整过程（包括踩过的每个坑及解决方法）？见
> [DEPLOYMENT.md](./DEPLOYMENT.md)。

### 仓库结构

```
devspace-stack/
├── docker-compose.yml        # devspace + cloudflared 两个服务
├── Dockerfile                # DevSpace 镜像 (node:22, 非 root, 健康检查)
├── .env.example              # 模板 —— 复制为 .env
├── .env                      # 你的密钥 (git-ignored)
├── .gitignore
├── LICENSE                   # MIT
├── THIRD-PARTY.md            # 第三方开源组件许可证声明
├── DEPLOYMENT.md             # 真实部署记录 + 踩坑 (中英双语)
├── devspace-config/
│   └── config.json           # 非密钥的 DevSpace 配置 (allowed roots 等)
├── cloudflared/
│   ├── setup-tunnel.sh       # 一次性 Cloudflare 隧道配置脚本
│   ├── config.yml.example    # 隧道 ingress 模板 (已提交)
│   ├── config.yml            # 每台机器各自生成 (git-ignored)
│   └── credentials.json      # 隧道凭证 (git-ignored, 由脚本创建)
└── workspace/                # 你的本地代码, 挂载进容器
```

### 前置条件

- 任意带 Docker + Docker Compose v2 的 Linux（WSL2 Ubuntu、Debian、Ubuntu 等）
- 一个 Cloudflare 账号和一个你控制的域名
- 主机上安装 `cloudflared` CLI（用于一次性隧道配置）
- 主机**不需要** Node.js —— 它在镜像里

### 1. 配置

```bash
cd devspace-stack
cp .env.example .env
```

编辑 `.env`：

| 变量 | 值 |
| --- | --- |
| `DEVSPACE_OAUTH_OWNER_TOKEN` | 长随机密钥（≥16 字符）：`openssl rand -base64 32`。这是你批准 MCP 客户端时输入的 **Owner 密码**，务必保密。 |
| `DEVSPACE_PUBLIC_BASE_URL` | 隧道公网源地址，**不带** `/mcp`，例如 `https://devspace.example.com` |
| `CLOUDFLARED_UID` / `CLOUDFLARED_GID` | 你的主机 UID:GID（`id -u` / `id -g`）—— 即 `cloudflared/credentials.json` 的属主用户 |
| `APT_MIRROR` / `NPM_REGISTRY` / `BUILD_FROM_SOURCE` | 可选构建调优，默认全部不设（走官方源）。若你的网络访问官方源很慢，可设 `APT_MIRROR=http://mirrors.tuna.tsinghua.edu.cn`、`NPM_REGISTRY=https://registry.npmmirror.com` 加速；`BUILD_FROM_SOURCE=true` 表示本地编译原生模块而非下载 GitHub 预编译包（适用于预编译包下载挂死的网络）。 |

非密钥的 DevSpace 配置在 `devspace-config/config.json`。关键项是 `allowedRoots` ——
DevSpace 可以打开的目录，默认设为 `/workspace`（挂载目录）。挂载更多目录时在这里加。

隧道本身由**文件**配置，而不是 `.env` 变量（见第 2 步）：
`cloudflared/config.yml`（ingress）和 `cloudflared/credentials.json`（凭证）。

### 2. 创建 Cloudflare 隧道（一次性）

在主机上运行（传入你自己的公网域名）：

```bash
./cloudflared/setup-tunnel.sh devspace.example.com
```

它会：
1. 登录 Cloudflare（打开浏览器）—— 仅首次
2. 创建名为 `devspace` 的隧道
3. 把你的域名路由到隧道（DNS CNAME）
4. 把隧道凭证复制到 `cloudflared/credentials.json`
5. 从 `config.yml.example` 生成 `cloudflared/config.yml`（填入你的隧道 UUID 和域名）

ingress（哪个域名映射到哪个服务）定义在 `cloudflared/config.yml`。仓库里提交的是
模板 `cloudflared/config.yml.example`；生成的 `config.yml` 是每台机器各自的，
git-ignored。

> **为什么用文件而不是 token？** cloudflared 2026.x 移除了 `tunnel routing` 和
> `tunnel token` 子命令。现在运行 named tunnel 的官方方式是：凭证文件 + 定义
> ingress 的配置文件。容器运行
> `cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`。
> 不需要 token，不需要 dashboard。

### 3. 启动栈

```bash
docker compose up -d
```

等 DevSpace 变为 healthy：

```bash
docker compose ps
# devspace      ...   healthy
# cloudflared   ...   running
```

### 4. 验证

**健康检查（无鉴权）：**
```bash
curl -fsS https://devspace.example.com/healthz
# {"ok":true,"name":"devspace"}
```

**MCP 端点**需要 OAuth。把你的 MCP 客户端（ChatGPT / Codex / Claude）指向：

```
https://devspace.example.com/mcp
```

首次连接时 DevSpace 会显示批准页 —— 输入 **Owner 密码**
（`DEVSPACE_OAUTH_OWNER_TOKEN`）。之后客户端就能打开 `/workspace` 下的项目并
读/写/运行代码。

### 5. 连接 MCP 客户端

把端点加进客户端的 MCP 配置：

```json
{
  "mcpServers": {
    "devspace": {
      "url": "https://devspace.example.com/mcp"
    }
  }
}
```

ChatGPT 里作为自定义 connector / App 添加，指向 `/mcp` URL 即可。

### 日志

```bash
docker compose logs -f devspace     # DevSpace 服务器 (JSON 日志)
docker compose logs -f cloudflared  # 隧道状态 / 重连
docker compose logs --tail=100      # 两者
```

DevSpace 默认记录请求和工具调用。想看 shell 命令预览，在 `config.json` 里设置
`DEVSPACE_LOG_SHELL_COMMANDS=1`（仅当命令不含密钥时）。

### 重启 / 恢复

容器设置了 `restart: unless-stopped`，Docker 守护进程启动时会自动回来。重启后：

```bash
# 1. 确认 Docker 在运行
sudo systemctl start docker        # systemd 主机 (物理 Linux、虚拟机)
# WSL2: sudo service docker start, 或直接打开一个 WSL 终端

# 2. 把栈拉起来 (已在运行则是空操作)
cd devspace-stack
docker compose up -d

# 3. 确认
docker compose ps
curl -fsS https://devspace.example.com/healthz
```

如果容器卡在 `restarting`，看日志：
```bash
docker compose logs --tail=50 devspace
```

常见原因：
- **宿主机 7676 端口被占用** —— 停掉占用进程。
- **`cloudflared/credentials.json` 缺失** —— 重跑 `./cloudflared/setup-tunnel.sh <域名>` 复制进来。
- **隧道没路由** —— 检查 `cloudflared/config.yml` 的 `hostname:` 和 `service:` 是否正确。
- **`better-sqlite3 could not load`** —— 重建镜像：`docker compose build --no-cache devspace`。

### 升级 DevSpace

改 `Dockerfile` 里的 `DEVSPACE_VERSION`（或去掉版本锁定跟随 latest），然后：

```bash
docker compose build devspace
docker compose up -d
```

### 安全说明

- **无公网端口。** 唯一面向互联网的入口是 Cloudflare Tunnel 域名。
- **OAuth owner-token** 保护 MCP 端点。任何拿到 Owner 密码的人都能批准客户端 ——
  当密码对待。
- **`allowedRoots`** 是文件系统白名单。保持最小（只有 `/workspace`）。
- shell 工具以容器用户身份执行命令。已连接的客户端相当于一个能访问挂载 workspace
  的受信任编码伙伴。
- 想再加一层保护，可以在隧道域名前加 **Cloudflare Access**（不在本项目范围内，
  但是很自然的下一步）。

### 拆除

```bash
docker compose down          # 停止并删除容器 (保留卷)
docker compose down -v       # 同时删除 state/worktree 卷
# 删除隧道 + DNS 记录:
cloudflared tunnel delete devspace
```

### 许可证

本仓库代码（Dockerfile、compose 文件、配置模板、安装脚本）采用 **MIT License** ——
见 [LICENSE](./LICENSE)。

本项目打包并运行第三方开源软件（DevSpace、cloudflared 及其依赖），其许可证列于
[THIRD-PARTY.md](./THIRD-PARTY.md)。
