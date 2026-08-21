#!/usr/bin/env bash
# =============================================================================
# Cloudflare Tunnel setup for DevSpace
#
# Run this ONCE on the WSL host (not inside a container) to:
#   1. Log in to Cloudflare (opens a browser)
#   2. Create a named tunnel
#   3. Route your public hostname to the tunnel (DNS CNAME)
#   4. Copy the tunnel credentials into this project
#   5. Generate cloudflared/config.yml from the template
#
# Usage:
#   ./cloudflared/setup-tunnel.sh devspace.gongshl.top
#
# The hostname must be a domain you control in your Cloudflare account.
#
# NOTE: cloudflared 2026.x removed the `tunnel routing` and `tunnel token`
# CLI subcommands. Ingress (hostname -> service) is now defined in
# cloudflared/config.yml, and the tunnel runs from the credentials file
# (cloudflared/credentials.json) that this script copies into the project.
# No token is needed.
# =============================================================================
set -euo pipefail

HOSTNAME="${1:-}"
TUNNEL_NAME="devspace"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

if [[ -z "${HOSTNAME}" ]]; then
  echo "Usage: $0 <public-hostname>"
  echo "Example: $0 devspace.gongshl.top"
  exit 1
fi

# Strip scheme if the user pasted a full URL.
HOSTNAME="${HOSTNAME#https://}"
HOSTNAME="${HOSTNAME#http://}"
HOSTNAME="${HOSTNAME%/}"

echo "==> Tunnel name : ${TUNNEL_NAME}"
echo "==> Public host : ${HOSTNAME}"
echo "==> Target      : http://devspace:7676  (internal Docker network)"
echo

# --- 1. Login (interactive: opens a browser) --------------------------------
if [[ ! -f "${HOME}/.cloudflared/cert.pem" ]]; then
  echo "==> No Cloudflare credentials found. Logging in (a browser will open)..."
  cloudflared tunnel login
else
  echo "==> Cloudflare credentials already present (${HOME}/.cloudflared/cert.pem)."
fi
echo

# --- 2. Create the tunnel (idempotent) --------------------------------------
if cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "${TUNNEL_NAME}"; then
  echo "==> Tunnel '${TUNNEL_NAME}' already exists."
else
  echo "==> Creating tunnel '${TUNNEL_NAME}'..."
  cloudflared tunnel create "${TUNNEL_NAME}"
fi
echo

# --- 3. Route DNS: public hostname -> tunnel --------------------------------
echo "==> Routing DNS: ${HOSTNAME} -> tunnel '${TUNNEL_NAME}'"
cloudflared tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}"
echo

# --- 4. Copy the tunnel credentials into the project ------------------------
# `cloudflared tunnel create` writes a <TunnelID>.json file into ~/.cloudflared/.
# Find the one that matches our tunnel name and copy it to cloudflared/credentials.json.
CRED_SRC="$(cloudflared tunnel list 2>/dev/null \
  | awk -v name="${TUNNEL_NAME}" '$2 == name {print $1}' \
  | head -n1)"
if [[ -z "${CRED_SRC}" ]]; then
  echo "ERROR: could not find tunnel '${TUNNEL_NAME}' in \`cloudflared tunnel list\`." >&2
  exit 1
fi
# CRED_SRC is the TunnelID (UUID); the credentials file is ~/.cloudflared/<UUID>.json
CRED_FILE="${HOME}/.cloudflared/${CRED_SRC}.json"
if [[ ! -f "${CRED_FILE}" ]]; then
  echo "ERROR: credentials file not found at ${CRED_FILE}" >&2
  exit 1
fi
cp "${CRED_FILE}" "${SCRIPT_DIR}/credentials.json"
chmod 600 "${SCRIPT_DIR}/credentials.json"
echo "==> Copied tunnel credentials to ${SCRIPT_DIR}/credentials.json"
echo

# --- 5. Generate config.yml from the template -------------------------------
# config.yml is per-machine (it embeds your tunnel UUID + hostname), so it is
# git-ignored. Generate it from the committed template.
sed -e "s/__TUNNEL_ID__/${CRED_SRC}/g" \
    -e "s/__HOSTNAME__/${HOSTNAME}/g" \
    "${SCRIPT_DIR}/config.yml.example" > "${SCRIPT_DIR}/config.yml"
echo "==> Generated ${SCRIPT_DIR}/config.yml (tunnel ${CRED_SRC}, host ${HOSTNAME})"
echo

echo "============================================================"
echo " Done. The tunnel is configured via files (no token needed):"
echo
echo "   cloudflared/config.yml        (ingress: ${HOSTNAME} -> http://devspace:7676)"
echo "   cloudflared/credentials.json  (tunnel credentials, git-ignored)"
echo
echo " Make sure .env has:"
echo "   DEVSPACE_PUBLIC_BASE_URL=https://${HOSTNAME}"
echo
echo " Then start the stack:"
echo "   cd ${PROJECT_DIR} && docker compose up -d"
echo "============================================================"
