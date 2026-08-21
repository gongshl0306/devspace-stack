# DevSpace MCP Stack (WSL2 + Docker + Cloudflare Tunnel)

Self-hosted [DevSpace](https://github.com/Waishnav/devspace) MCP server, containerized
with Docker Compose and exposed over HTTPS through a **Cloudflare Tunnel** on your own
domain. No public ports are opened — the tunnel connects *outbound* to Cloudflare's edge.

> 📖 Looking for a real-world deployment walkthrough (including every pitfall and how
> it was fixed)? See [DEPLOYMENT.md](./DEPLOYMENT.md) — a bilingual record of deploying
> this stack on WSL2.

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
Your local code (WSL2)
```

## What's in this repo

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

## Prerequisites

- WSL2 Ubuntu with Docker + Docker Compose v2
- A Cloudflare account with a domain you control
- `cloudflared` CLI on the WSL host (for the one-time tunnel setup)
- Node `>=22.19 <27` is **not** needed on the host — it's inside the image

## 1. Configure

```bash
cd devspace-stack
cp .env.example .env
```

Edit `.env`:

| Variable | Value |
| --- | --- |
| `DEVSPACE_OAUTH_OWNER_TOKEN` | A long random secret (≥16 chars). Generate: `openssl rand -base64 32`. This is the **Owner password** you enter to approve MCP clients. Keep it private. |
| `DEVSPACE_PUBLIC_BASE_URL` | Your tunnel origin **without** `/mcp`, e.g. `https://devspace.example.com` |

The tunnel itself is configured by **files**, not `.env` variables (see step 2):
`cloudflared/config.yml` (ingress) and `cloudflared/credentials.json` (credentials).

The non-secret DevSpace config lives in `devspace-config/config.json`. The key setting is
`allowedRoots` — the folders DevSpace may open. It's set to `/workspace` (the mounted
directory). Add more roots there if you mount more directories.

## 2. Create the Cloudflare Tunnel (one-time)

Run on the WSL host (pass your own public hostname):

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

## 3. Start the stack

```bash
docker compose up -d
```

Wait for DevSpace to become healthy:

```bash
docker compose ps
# devspace      ...   healthy
# cloudflared   ...   running
```

## 4. Verify

**Health (no auth):**
```bash
curl -fsS http://127.0.0.1:7676/healthz
# {"ok":true,"name":"devspace"}
```

**Public HTTPS endpoint:**
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

## 5. Connect an MCP client

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

## Logs

```bash
docker compose logs -f devspace     # DevSpace server (JSON logs)
docker compose logs -f cloudflared  # tunnel status / reconnects
docker compose logs --tail=100      # both
```

DevSpace logs requests and tool calls by default. To see shell command previews, set
`DEVSPACE_LOG_SHELL_COMMANDS=1` in `config.json` (only if commands contain no secrets).

## WSL restart / recovery

Docker containers are set to `restart: unless-stopped`, so they come back automatically
when the Docker daemon starts. After a WSL reboot:

```bash
# 1. Make sure Docker is running in WSL
sudo service docker start        # if the daemon isn't up

# 2. Bring the stack up (no-op if already running)
cd devspace-stack
docker compose up -d

# 3. Confirm
docker compose ps
curl -fsS http://127.0.0.1:7676/healthz
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

## Updating DevSpace

Bump `DEVSPACE_VERSION` in the `Dockerfile` (or remove the pin to track latest), then:

```bash
docker compose build devspace
docker compose up -d
```

## Security notes

- **No public ports.** The only internet-facing entry is the Cloudflare Tunnel hostname.
- **OAuth owner-token** protects the MCP endpoint. Anyone with the Owner password can
  approve a client — treat it like a password.
- **`allowedRoots`** is the filesystem allowlist. Keep it narrow (just `/workspace`).
- The shell tool runs commands as the container user. A connected client is effectively
  a trusted coding partner with access to the mounted workspace.
- For extra protection, add **Cloudflare Access** in front of the tunnel hostname
  (out of scope here, but a natural next step).

## Teardown

```bash
docker compose down          # stop + remove containers (keeps volumes)
docker compose down -v       # also remove state/worktree volumes
# remove the tunnel + its DNS record:
cloudflared tunnel delete devspace
```

## License

This repository's code (Dockerfile, compose file, config templates, and setup
scripts) is licensed under the **MIT License** — see [LICENSE](./LICENSE).

This project packages and runs third-party open-source software (DevSpace,
cloudflared, and their dependencies). Their licenses are listed in
[THIRD-PARTY.md](./THIRD-PARTY.md).
