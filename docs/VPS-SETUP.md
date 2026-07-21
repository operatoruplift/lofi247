# VPS Setup

Everything to take a fresh Ubuntu 24.04 VPS to a running 24/7 station. The
bootstrap script [`scripts/vps-setup.sh`](../scripts/vps-setup.sh) automates the
system-level steps (Docker, firewall, directories) and is safe to re-run; this doc
explains each step so you can do it by hand or audit what the script does.

## 1. Sizing

The only heavy process is the FFmpeg streamer encoding x264 in real time. Rules of
thumb (x264 `veryfast`, mostly-static lofi visuals):

| Target | vCPU | RAM | Notes |
|---|---|---|---|
| **720p30 (default)** | **2** | **4 GB** | Comfortable — encode uses roughly one core, everything else is noise |
| 1080p30 | 4 | 8 GB | x264 cost scales ~2.25× with pixel count |
| 720p30 on 1 vCPU / 2 GB | possible | tight | Works until it doesn't; frame drops under any co-tenant CPU steal |

RAM is never the constraint — Liquidsoap, Icecast, and nginx together use a few
hundred MB. Disk: 20 GB base + your music/visuals library.

**Bandwidth is the number to actually check.** A 24/7 stream at the default
`VIDEO_BITRATE=3500k` + audio ≈ 3.7 Mbps sustained:

```
3.7 Mbit/s × 86,400 s/day × 30 days ≈ 1.2 TB/month egress — just to X
```

Web player listeners add ~320 kbps each on top (they consume the Icecast MP3
mount, which liquidsoap encodes at 320 kbps). Compare that against provider
egress allowances before choosing.

### Provider options (prices as of mid-2026 — verify before buying)

| Provider / plan | Spec | ~Price | Included egress |
|---|---|---|---|
| **Hetzner CX23** (EU) / **CPX-line** (US) | 2 vCPU / 4 GB | ~€5.50/mo (after the June 2026 price adjustment) | 20 TB — the easy winner on bandwidth |
| **DigitalOcean Basic Droplet** | 2 vCPU / 4 GB | $24/mo | 4 TB |
| **Vultr Cloud Compute** | 2 vCPU / 4 GB | ~$24–30/mo by region | ~3 TB pooled — fine for X-only, tight with listeners |

Hetzner is the price/bandwidth sweet spot (note: the older CPX21 plan referenced
in many guides has been superseded — pick whatever current 2 vCPU / 4 GB tier is
offered in your region). For 1080p, Hetzner CPX31/CX33-class (4 vCPU) is still
cheaper than the 2-vCPU tier at the US providers. All three have one-click
Ubuntu 24.04 images.

## 2. First login: user + SSH hardening

As root on the fresh box:

```bash
adduser lofi
usermod -aG sudo lofi

# Give the new user your SSH key
rsync --archive --chown=lofi:lofi ~/.ssh /home/lofi
```

Then harden SSH — key-only auth, no root login:

```bash
cat >/etc/ssh/sshd_config.d/60-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
systemctl reload ssh
```

> [!IMPORTANT]
> Verify you can open a **new** SSH session as `lofi` with your key **before**
> closing the root session. The bootstrap script only disables password auth if
> it finds an `authorized_keys` file for exactly this reason.

Optional but recommended: enable unattended security updates
(`apt install unattended-upgrades` — the script does this).

## 3. Install Docker

Via Docker's apt repository (GPG-verified packages — this box will hold your
stream key and Soulseek credentials, so skip the pipe-a-script-to-shell path):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker lofi
sudo systemctl enable --now docker
# log out and back in for the group to apply
```

(`scripts/vps-setup.sh` does all of this for you.)

## 4. Firewall (UFW)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 8080/tcp comment 'lofi247 web player'
sudo ufw --force enable
sudo ufw status verbose
```

What stays **closed**, and why:

- **8000 (Icecast)** — internal only. The web container reverse-proxies `/radio`
  on 8080, so browsers never need Icecast directly. Exposing it invites hotlinking
  and gives attackers the admin UI to brute-force.
- **5030 (slskd)** — a logged-in web UI with your Soulseek credentials. Reach it
  through an SSH tunnel instead:

  ```bash
  ssh -L 5030:localhost:5030 lofi@your-vps
  # then open http://localhost:5030 locally
  ```

  or put the VPS on a [Tailscale](https://tailscale.com/) tailnet and bind the
  port to the tailnet IP.

One port **is** intentionally public while slskd runs:

- **50300 (Soulseek peer port)** — published to `0.0.0.0` by the `acquire`
  profile because Soulseek peers must reach it for transfers. It is only open
  while slskd is up; `docker compose --profile acquire stop slskd` closes it.
  This is a conscious trade-off, not an oversight — treat starting the acquire
  profile as opening a port to the internet.

> [!WARNING]
> **Docker bypasses UFW.** Ports *published* by Docker (`ports:` in compose) are
> opened via iptables directly and UFW rules do not filter them. UFW protects
> host services, not published container ports. So the real control is the
> compose file: ports that should be private must either not be published at all
> (Icecast) or be published bound to localhost (`127.0.0.1:5030:5030` style).
> Check `docker compose ps` after starting — anything showing `0.0.0.0:PORT` is
> reachable from the internet regardless of UFW.

## 5. Deploy

Steps 2–4 above are exactly what the bootstrap script automates. If you did them
by hand you can jump to **Clone and launch**. From a bare box, do it in this
order — the ordering is not optional, because the bootstrap is what *creates* the
`lofi` user, so you cannot `ssh lofi@your-vps` until after it has run.

### Step 1 — bootstrap (as `root`, once)

The script lives in the repo, so grab the repo first just to run it (a fresh
Ubuntu image may not ship `git`):

```bash
# on the fresh box, logged in as root
apt-get update && apt-get install -y git
git clone https://github.com/YOURNAME/lofi247.git /root/lofi247-bootstrap
/root/lofi247-bootstrap/scripts/vps-setup.sh
```

This creates the `lofi` user, installs Docker (+ the compose plugin), opens the
firewall, and hardens SSH. It is idempotent — safe to re-run. `/root/lofi247-bootstrap`
is a throwaway copy used only to launch the script; the real, `lofi`-owned checkout
comes in step 3.

> [!IMPORTANT]
> The bootstrap creates `lofi` with **no password and no SSH key yet**, so it does
> *not* disable password auth (that would lock you out — see section 2). Two ways
> to become `lofi`:
> - **Quickest:** `su - lofi` from your current root session. A fresh login shell
>   is also what activates the new `docker` group membership.
> - **Hardened box:** first give `lofi` your key from the root session
>   (`rsync --archive --chown=lofi:lofi ~/.ssh /home/lofi`), confirm a **new**
>   `ssh lofi@your-vps` session works with it, then re-run the bootstrap so it
>   enforces key-only auth.

### Step 2 — become `lofi`

`su - lofi` (or reconnect over SSH as `lofi` once its key is in place). Everything
below runs as `lofi`.

### Step 3 — clone and launch

Clone into the default `REPO_DIR` (`/home/lofi/lofi247`) and bring the stack up:

```bash
git clone https://github.com/YOURNAME/lofi247.git ~/lofi247
cd ~/lofi247
cp .env.example .env
nano .env      # X_RTMP_URL, X_STREAM_KEY, Icecast passwords, station branding
docker compose up -d
```

No X stream key yet? Leave `X_STREAM_KEY` at its placeholder and the streamer runs
in **preview mode** — Icecast and the `:8080` web player come up while the encoder
stays idle, so you can verify the stack before you have X Premium or a key (see
[X-STREAMING.md](X-STREAMING.md#3-put-them-in-env)). Add music and visuals next
(section 6), then `./scripts/status.sh` to confirm.

With the optional Soulseek client:

```bash
docker compose --profile acquire up -d
```

> [!NOTE]
> **Cloning somewhere other than `/home/<user>/lofi247`?** The bootstrap's
> `REPO_DIR` defaults to `/home/${LOFI_USER}/lofi247`. If your checkout lives
> elsewhere, pass the path when you run (or re-run) the script so it prepares the
> right content directories: `sudo REPO_DIR=/srv/lofi247 ./scripts/vps-setup.sh`.
> The `music/`, `visuals/`, and `downloads/` directories otherwise come from the
> clone itself — re-running the bootstrap after cloning just (re)asserts their
> ownership and permissions.

## 6. Getting music and visuals onto the box

From your **local machine** (rsync is resumable and only transfers changes):

```bash
# music library → broadcast folder (--chmod=F644: see the permissions note below)
rsync -av --progress --chmod=F644 ~/lofi-library/ lofi@your-vps:~/lofi247/music/

# ambient video loops
rsync -av --progress --chmod=F644 ~/loops/ lofi@your-vps:~/lofi247/visuals/

# one-off files, scp works too (then chmod 644 on the box if your umask is tight)
scp track.mp3 lofi@your-vps:~/lofi247/music/
```

Files must be world-readable (`chmod 644`) — liquidsoap runs as a dedicated
non-root uid inside its container, so a track rsynced with tight permissions
(e.g. from a `umask 077` machine) silently never airs. `rsync --chmod=F644`
handles it in one flag.

Liquidsoap watches the playlist directory — new tracks enter rotation without a
restart (worst case: `docker compose restart liquidsoap`). Prep visuals with
`scripts/prep-visual.sh` before uploading (see [VISUALS.md](VISUALS.md)) so the
streamer isn't transcoding oddball codecs at runtime.

If you use slskd, downloads land in `~/lofi247/downloads/` — curate them into the
library with `scripts/ingest-music.sh` (see [MUSIC.md](MUSIC.md)). Nothing in
`downloads/` ever broadcasts directly.

## 7. Operating

```bash
./scripts/status.sh                        # one-glance: services, logs, now playing, listeners

docker compose logs -f streamer            # follow the RTMP push
docker compose logs -f liquidsoap          # playlist engine
docker compose logs --tail 100 icecast

docker compose restart streamer            # bounce just the encoder (X reconnects)
docker compose down && docker compose up -d   # full bounce
```

### Updating

```bash
cd ~/lofi247
git pull
docker compose pull          # refresh upstream images (icecast, nginx, slskd…)
docker compose build streamer   # rebuild the custom ffmpeg image if it changed
docker compose up -d         # recreates only what changed
docker image prune -f
```

The streamer's retry loop and X's reconnect grace window mean a quick update is
usually invisible to viewers — see
[X-STREAMING.md](X-STREAMING.md#6-247-operation-how-restarts-interact-with-x-broadcasts)
for how longer outages interact with broadcasts.

### If things look wrong

1. `./scripts/status.sh` — is every service `Up`? Is the mount live?
2. Empty `music/`? The station falls back to the ambient bed (or silence) by
   design — it should never crash. Check `liquidsoap` logs.
3. Disk full (downloads folder is the usual suspect): `df -h`, then prune.
4. CPU pegged >90% sustained: lower `VIDEO_BITRATE`/resolution, or resize the VPS.
