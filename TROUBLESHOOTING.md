# Troubleshooting

First-run failure modes, keyed by **what you actually see**. Almost every one of
these is a wiring or content problem, not a bug — the stack is built to degrade
(empty library → ambient bed → silence) rather than crash, so "all services `Up`"
tells you less than you'd think.

**Start here, always:**

```bash
./scripts/status.sh                 # services, mount state, now playing, listeners
docker compose logs -f streamer     # the RTMP push to X
docker compose logs -f liquidsoap   # the playlist engine
docker compose logs --tail 100 icecast
```

Jump to your symptom:

- [The streamer keeps reconnecting / spams the log](#1-the-streamer-keeps-reconnecting--spams-the-log)
- [My tracks don't play, but every service is "Up"](#2-my-tracks-dont-play-but-every-service-is-up)
- [The web player is blank / has no audio](#3-the-web-player-is-blank--has-no-audio)
- [The encoder connected but I'm not live on X](#4-the-encoder-connected-but-im-not-live-on-x)
- [No audio at all, anywhere](#5-no-audio-at-all-anywhere)

---

## 1. The streamer keeps reconnecting / spams the log

Two very different situations wear this look — read the log to tell them apart.

**The streamer says it's idle / in preview mode.** Your `X_STREAM_KEY` is still the
unedited `.env.example` placeholder (`your-x-stream-key`). This is **preview mode**,
not an error: the streamer deliberately does not push until you give it a real key, so
Icecast and the `:8080` web player can run while you set X up. Fill in the real key and
`docker compose up -d` (or `docker compose restart streamer`).

**The streamer connects, then drops every few seconds, on repeat.** ffmpeg is reaching
X but the push is being rejected. Usual causes:

- Wrong or rotated stream key, or a second encoder pushing to the same source.
- `X_RTMP_URL` malformed — missing the `/x` app path, or a trailing slash.
- The RTMPS endpoint for your region misbehaving — try the plain `rtmp://...:80/x`
  fallback form.

See: [docs/X-STREAMING.md § 3 — Put them in `.env`](docs/X-STREAMING.md#3-put-them-in-env)
and [§ 8 — Troubleshooting](docs/X-STREAMING.md#8-troubleshooting).

---

## 2. My tracks don't play, but every service is "Up"

You hear the ambient fallback bed instead of your library, and nothing errors. This is
almost always **file permissions**.

Liquidsoap runs as a dedicated **non-root uid** inside its container. A track copied
from a tight-umask machine (e.g. `umask 077`) lands mode `600` — liquidsoap can't read
it, so it silently drops out of rotation and the fallback bed plays. Every service
stays `Up` because nothing crashed.

Fix on the box:

```bash
chmod 644 ~/lofi247/music/*.mp3
```

And prevent it at the source — sync with `--chmod=F644`:

```bash
rsync -av --chmod=F644 ~/lofi-library/ lofi@your-vps:~/lofi247/music/
```

Also confirm the library isn't simply empty (an empty `music/` also falls back to the
bed), and that files are actually tagged/ingested — untagged or unconverted files can
be skipped.

See: [docs/VPS-SETUP.md § 6 — Getting music and visuals onto the box](docs/VPS-SETUP.md#6-getting-music-and-visuals-onto-the-box),
[docs/MUSIC.md § 4 — Ingest flow](docs/MUSIC.md#4-ingest-flow), and the checklist in
[docs/VPS-SETUP.md — If things look wrong](docs/VPS-SETUP.md#if-things-look-wrong).

---

## 3. The web player is blank / has no audio

The page at `http://your-vps:8080` loads but shows nothing, or the visualizer is dead
and there's no sound. The web player consumes Icecast through nginx's `/radio` reverse
proxy, so the fault is between those two:

- **Is Icecast healthy and the mount live?** `./scripts/status.sh` reports the mount
  and listener count. If the mount is down, the player has nothing to play — check
  `docker compose logs icecast` and whether liquidsoap is connected as a source.
- **Is the `/radio` proxy reachable?** `curl -sI http://your-vps:8080/radio` should
  return an audio stream, not a 404/502. A 502 means nginx can't reach the Icecast
  container; a 404 means the mount isn't published yet.
- **Firewall:** port `8080/tcp` must be open (the bootstrap opens it). Icecast's
  `8000` stays closed on purpose — the browser only ever talks to `8080`.

See: [docs/VPS-SETUP.md § 7 — Operating](docs/VPS-SETUP.md#7-operating) and the port
rationale in [docs/VPS-SETUP.md § 4 — Firewall (UFW)](docs/VPS-SETUP.md#4-firewall-ufw).

---

## 4. The encoder connected but I'm not live on X

The streamer logs look clean, X shows the source as *receiving*, there's a preview in
Live Studio — and still nothing on your timeline.

That's expected: **a connected encoder is not a public broadcast.** X only starts
showing the stream to the world after you click **Go Live** in X Live Studio.
*Receiving* / preview and *live* are two separate states. A successful RTMP push only
gets you to the first one; the last click is manual.

(And once you're live: X caps a single livestream at ~24 h, so the channel needs a
brief daily broadcast rotation to stay visibly live.)

See: [docs/X-STREAMING.md § 4 — Create a broadcast and go live](docs/X-STREAMING.md#4-create-a-broadcast-and-go-live)
and [§ 6 — 24/7 operation](docs/X-STREAMING.md#6-247-operation-how-restarts-interact-with-x-broadcasts).

---

## 5. No audio at all, anywhere

Silence on the web player *and* the X stream (as opposed to [symptom 2](#2-my-tracks-dont-play-but-every-service-is-up),
where the ambient bed plays). The audio chain is designed to fall back
**library → ambient bed → silence**, so true silence means it fell all the way
through — the source itself isn't producing sound:

- **Is liquidsoap running and publishing to Icecast?** `docker compose logs
  liquidsoap` — look for it connecting as a source. If it can't reach Icecast, check
  `ICECAST_SOURCE_PASSWORD` matches on both sides in `.env`.
- **Empty library *and* missing fallback?** An empty `music/` should still give you the
  ambient bed (`assets/ambient-fallback.mp3`). If even that is gone, you get silence —
  add tracks (or restore the fallback asset).
- **Mount down?** If Icecast has no live mount, both consumers (streamer and web
  player) have nothing to pull. Confirm with `./scripts/status.sh`.

See: [docs/VPS-SETUP.md — If things look wrong](docs/VPS-SETUP.md#if-things-look-wrong)
and the fallback design in the [README Architecture](README.md#architecture) section.
