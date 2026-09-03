# Stable deployment

**Current primary judging backend (Google Cloud, free-tier e2-micro, us-central1):**

* Foundry console: https://foundry.136.111.215.133.nip.io
* Ledgerly app: https://ledgerly.136.111.215.133.nip.io

Topology: `public HTTPS (Caddy, Let's Encrypt, nip.io names on a static IP) → Foundry :8090 / Ledgerly :8091
(one systemd-managed Julia process, Restart=always, enabled at boot)`. The ledger and runtime state live in
`/opt/webmcp-foundry/data` on the boot disk. Provisioning is one idempotent script:

```bash
gcloud compute scp deploy/gcp-provision.sh webmcp-foundry:/tmp/provision.sh --zone us-central1-a
gcloud compute ssh webmcp-foundry --zone us-central1-a -- bash /tmp/provision.sh foundry.<ip>.nip.io ledgerly.<ip>.nip.io main
```

To drive the cloud pair with the test drivers from a workstation, forward the two ports over SSH and set
`FPORT`/`APORT` (`gcloud compute ssh webmcp-foundry --zone us-central1-a -- -N -L 18090:127.0.0.1:8090 -L 18091:127.0.0.1:8091`,
then `FPORT=18090 APORT=18091 WEBMCP_PAGE=https://ledgerly.<ip>.nip.io/ julia test/acceptance_native.jl --attach`).
The browser side always uses the public HTTPS origin, so WebMCP's secure-context requirement holds.

Three modes.

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
