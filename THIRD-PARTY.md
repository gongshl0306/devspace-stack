# Third-Party Components & Licenses

This project is a **deployment scaffold** — it does not re-implement the
software it runs. It packages and wires together several third-party open-source
components. This file lists them and their licenses, as required by those
licenses.

The code in *this* repository (the Dockerfile, compose file, config templates,
and setup scripts) is licensed under the **MIT License** — see [LICENSE](./LICENSE).

## Directly referenced components

| Component | What it is | License | Copyright |
| --- | --- | --- | --- |
| [DevSpace](https://github.com/Waishnav/devspace) (`@waishnav/devspace`) | The self-hosted MCP server this stack runs. Installed into the image via `npm install -g`. | MIT | (c) 2026 Waishnav |
| [cloudflared](https://github.com/cloudflare/cloudflared) | Cloudflare Tunnel client. Runs as the `cloudflared` container (`cloudflare/cloudflared` image). | BSD-3-Clause | (c) Cloudflare, Inc. |

## Bundled into the DevSpace image (transitive dependencies)

These are pulled in by `npm install -g @waishnav/devspace` and shipped inside the
`devspace` container image. They are not vendored in this repo.

| Component | Role | License |
| --- | --- | --- |
| [express](https://github.com/expressjs/express) | HTTP framework used by DevSpace | MIT |
| [better-sqlite3](https://github.com/WiseLibs/better-sqlite3) | SQLite driver (native module) | MIT |
| [@modelcontextprotocol/sdk](https://github.com/modelcontextprotocol/typescript-sdk) | MCP protocol SDK | MIT |

## Base images & runtimes

| Component | Role | License |
| --- | --- | --- |
| [Node.js](https://nodejs.org/) | JavaScript runtime (`node:22-bookworm-slim` base image) | MIT (with exceptions) |
| [Debian GNU/Linux](https://www.debian.org/) | Base OS of the `node:22-bookworm-slim` image | Various (see Debian's license terms) |

## Notes

- **DevSpace** is the primary dependency. Its full MIT license text is reproduced
  in its own repository: <https://github.com/Waishnav/devspace/blob/main/LICENSE>.
- **cloudflared** is distributed as a prebuilt Docker image; its BSD-3-Clause
  license is in the upstream repo: <https://github.com/cloudflare/cloudflared/blob/main/LICENSE>.
- No source from these projects is copied into this repository. They are
  installed/pulled at build and run time, so their respective licenses apply to
  the built image and the running containers.
