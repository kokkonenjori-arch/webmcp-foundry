# Stable deployment

Two modes.

**A. VPS with fixed hostnames (recommended for judging).** Needs any Linux host with Docker and
ports 80/443, plus two DNS names. Caddy obtains TLS certificates automatically.

```bash
# on the VPS
git clone https://github.com/kokkonenjori-arch/webmcp-foundry && cd webmcp-foundry
sed -i 's/foundry.example.com/<your-foundry-host>/; s/ledgerly.example.com/<your-app-host>/' deploy/Caddyfile deploy/docker-compose.yml
docker compose -f deploy/docker-compose.yml up -d --build
bash bin/healthcheck.sh https://<your-foundry-host> https://<your-app-host>
```

Restart behaviour: `restart: unless-stopped`; on boot the Foundry replays `data/ledger.jsonl`
and refuses to start on a broken chain (fail closed). The app's handler files are restored from
their `.v1.jl` sources if missing.

**B. Supervised tunnels from a workstation** (`bin/serve_public.sh`, optionally registered at
logon with `bin/install_autostart.ps1`). Public URLs are ephemeral, so judges are given the
**stable entry page** on GitHub Pages, which the supervisor updates whenever a tunnel rotates.
The workstation must stay awake and online.

Health: `bash bin/healthcheck.sh` probes `/health` on both origins, the manifest with CORS, and
that the app's config points at the public Foundry origin. The Foundry console's header shows
the same data live.
