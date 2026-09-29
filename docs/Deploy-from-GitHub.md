# 🚀 Deploy a silo from GitHub

Your silo is a **sovereign environment** — you run it on infrastructure you
control, and the SANKOR hub never touches it. The paths below all install the
same self-contained Docker stack (see [`docker/`](../docker/README.md)) straight
from this repository, on **your** server, with **your** credentials.

## What you need first

- A Linux VM you control (Ubuntu/Debian recommended) — **≥ 1 GB RAM** for the
  `minimal` stack, **≥ 4 GB** for `full`.
- **Ports 80 and 443** open to the internet.
- A **domain name** whose DNS `A` record points at the VM (Caddy uses it to get
  an automatic HTTPS certificate).
- From the SANKOR admin: this site's **website id**, the **hub URL**, and the
  **hub anon key**.

---

## Option 1 — One command on your server (simplest)

SSH into your VM and run:

```bash
curl -fsSL https://raw.githubusercontent.com/sengtha/sankor-byoi/main/install.sh \
  | sudo bash -s -- \
      --domain silo.example.com \
      --website-id <uuid-from-the-admin> \
      --hub-url https://hub.sankor.site \
      --hub-anon-key <hub-anon-key>
```

That installs Docker, clones this repo to `/opt/sankor-silo`, generates the
silo's JWT secret + API keys, and brings the stack up behind automatic HTTPS.
Re-run the same command any time to **update** in place — your `.env` and your
database are preserved.

Add `--profile full` for the full stack (Studio, GoTrue, Storage); it also needs
`--studio-password '<password>'`.

Optional feature keys can be passed as environment variables and are written
into `.env` automatically:

```bash
curl -fsSL https://raw.githubusercontent.com/sengtha/sankor-byoi/main/install.sh \
  | sudo GEMINI_API_KEY=... R2_BUCKET=... bash -s -- \
      --domain silo.example.com --website-id <uuid> --hub-anon-key <key>
```

---

## Option 2 — Deploy from your own GitHub fork (Actions)

Fully sovereign: it runs from **your fork**, with **your secrets**, to **your**
server. The SANKOR hub is not involved.

1. **Fork** this repository (keep the fork public so the installer is fetchable).
2. In your fork: **Settings → Secrets and variables → Actions** → add:

   | Secret | Required | What it is |
   |---|---|---|
   | `SSH_HOST` | ✅ | Your server's IP/hostname |
   | `SSH_USER` | ✅ | An SSH user with `sudo` (or `root`) |
   | `SSH_PRIVATE_KEY` | ✅ | A private key authorized on that server |
   | `SSH_KNOWN_HOSTS` | ✅ | Your server's SSH host key: run `ssh-keyscan -H <your-server>` from a machine you trust, check the fingerprint against your provider's console, and paste the output. The deploy refuses to connect to any other host key, so a spoofed server can never receive your secrets. |
   | `SANKOR_HUB_ANON_KEY` | ✅ | The hub's anon key (first install only) |
   | `SANKOR_HUB_URL` | ⬜ | Defaults to `https://hub.sankor.site` |
   | `STUDIO_PASSWORD` | ⬜ | Required for the `full` profile |
   | `GEMINI_API_KEY`, `AI_AGENT_CRON_SECRET` | ⬜ | AI blogging agent |
   | `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, `R2_PUBLIC_URL` | ⬜ | Cloudflare R2 media |

3. **Actions → Deploy Silo → Run workflow**, then enter your **domain**, pick a
   **profile**, and paste your **website id**.

The workflow SSHes into your server and runs `install.sh` from your fork, then
runs [`doctor.sh`](../docker/README.md) to confirm the silo is actually serving.
Run it again whenever you want to redeploy or update — the workflow deploys
whichever branch you launch it from.

> **Rotating secrets:** tick **force_rotate_secrets** to regenerate the JWT
> secret and both API keys. The previous `.env` is backed up next to it, and the
> **new `ANON_KEY` must be re-registered in the SANKOR admin** — the old one
> stops working immediately.

### How your secrets are handled

They are written to a `0600` file, copied to the server over `scp`, sourced by
the installer, and deleted on exit — so they never appear in the server's
process list, and only the silo's own `.env` retains them.

---

## After it's up

1. Read the silo's public URL and anon key off the server:

   ```bash
   sudo grep -E '^(SILO_DOMAIN|ANON_KEY)=' /opt/sankor-silo/docker/.env
   ```

2. In the **SANKOR admin → Connect your site**, paste that **Silo URL** and
   **Anon key**.

3. Check everything is healthy (containers up, schema applied, data API
   reachable, JWT coupling correct):

   ```bash
   cd /opt/sankor-silo/docker && sudo ./doctor.sh minimal
   ```

The hub only ever receives this silo's **public URL** and **anon key**. It never
needs — and never receives — `JWT_SECRET` or `SERVICE_ROLE_KEY`.

## Updating later

```bash
# Re-run the installer (Option 1 or the workflow) — secrets are preserved:
curl -fsSL https://raw.githubusercontent.com/sengtha/sankor-byoi/main/install.sh \
  | sudo bash -s -- --domain silo.example.com

# …or, on the server, re-apply the (idempotent) schema and pull new images:
cd /opt/sankor-silo/docker && sudo ./update.sh minimal
```
