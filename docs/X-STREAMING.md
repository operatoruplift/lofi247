# Streaming to X (Twitter)

How to get an RTMP ingest URL + stream key from X, which encoder settings X wants,
how this repo's `.env` maps onto them, and what 24/7 operation actually looks like
on X's side. Current as of **July 2026**.

> [!NOTE]
> In early July 2026 X rolled out **Live Studio** (inside Creator Studio at
> `studio.x.com`), which replaces the older **Media Studio Producer**. The RTMP
> workflow — create a Source, copy URL + key, attach it to a broadcast — is the
> same in both; menus may differ slightly while the rollout completes. This doc
> uses Live Studio terminology and notes Producer equivalents where they differ.
> (X is also funding a $1M creator livestream payout push alongside the launch —
> live video is a priority surface for them right now, which bodes well for reach.)

## 1. What you need

| Requirement | Detail |
|---|---|
| **X Premium** (or Premium+) | Free and Basic accounts **cannot** access Live Studio / Media Studio, which is where stream keys are generated. Any paid Premium tier that includes Media Studio access works. |
| A public account | Protected accounts can't broadcast publicly. |
| Account in good standing | Live access can be revoked for policy violations — including copyright strikes. See the licensing warning in the [README](../README.md). |

No separate application or approval process is needed beyond the Premium
subscription — once subscribed, `studio.x.com` unlocks.

## 2. Get your RTMP URL and stream key

1. Log in to X in a desktop browser and go to **[studio.x.com](https://studio.x.com)**.
2. Open **Sources** in the left nav (in Live Studio this lives under the Live section; in Media Studio Producer it's the "Sources" tab).
3. Click **Create Source** (top right).
4. Name it (e.g. `lofi247-vps`), make sure **RTMP** is selected, and pick the
   **region closest to your VPS** — this becomes your ingest endpoint. Regions map
   to endpoints like `va.pscp.tv` (US East / Virginia), plus Oregon, California,
   Frankfurt, Paris, Dublin, Tokyo, Seoul, Singapore, Sydney, Mumbai, São Paulo.
   The region **cannot be changed later**; delete and recreate if you picked wrong.
5. The source page shows your **RTMP URL** and **RTMP stream key**. Copy both.
   An **RTMPS** URL is also offered — prefer it (encrypted in transit; the
   RTMPS form is what this repo's example uses). Plain RTMP remains available
   as a fallback.

Notes on keys and sources:

- **Sources persist and are reusable.** One source can serve many broadcasts over
  many days — you do *not* mint a new key per stream. This is what makes 24/7
  restarts practical: the streamer container always pushes to the same URL + key.
- Accounts are limited to **100 sources**; hitting the cap silently fails to
  create new ones. You only need one.
- RTMP authentication (user/pass on the ingest) is not supported — the key *is*
  the credential. **Treat the stream key like a password.** Anyone with it can
  broadcast as you.

## 3. Put them in `.env`

```bash
# .env
X_RTMP_URL=rtmps://va.pscp.tv:443/x      # your region's ingest URL, no trailing slash
X_STREAM_KEY=xxxxxxxxxxxxxxxxxxxxxxxx    # from the source page — keep secret
```

Prefer the **RTMPS** form of the ingest URL (encrypted — the stream key is the
only credential protecting your broadcast); plain `rtmp://...:80/x` works as a
fallback if your region's RTMPS endpoint misbehaves.

The streamer pushes to `$X_RTMP_URL/$X_STREAM_KEY`. Never commit `.env` (it's
gitignored) and never paste the key into screenshots or logs.

## 4. Create a broadcast and go live

1. In Live Studio, open **Broadcasts** → **Create Broadcast**.
2. Set title, description, and a thumbnail image. Under **Source**, select the
   source you created.
3. Start the encoder on your VPS: `docker compose up -d` (the streamer connects
   automatically once Icecast is up).
4. The broadcast page shows a **preview** once X receives your feed. Check audio
   and the now-playing overlay.
5. Click **Go Live** (Live Studio also offers a *private test broadcast* — use it
   for your first run). The broadcast posts to your timeline.

## 5. Encoder settings X wants — and how this repo maps to them

X's published recommendations for RTMP ingest:

| X recommends | This repo's `.env` var | Suggested value |
|---|---|---|
| 1280×720 @ 30/60fps, or 1920×1080 @ 30fps | `STREAM_WIDTH` / `STREAM_HEIGHT` / `STREAM_FPS` | `1280` / `720` / `30` (default — right call for lofi visuals) |
| H.264/AVC video, Main or High profile (no HEVC) | — (baked into the streamer's ffmpeg args) | x264 |
| Video bitrate up to ~9 Mbps | `VIDEO_BITRATE` | `3500k` default — plenty for slow ambient loops; raise toward `6000k` for 1080p |
| Keyframe every 2 seconds | derived from `STREAM_FPS` (GOP = 2 × fps, within X's ≤3 s guidance) | `30` fps → keyframe interval 60 |
| AAC-LC audio, **128 kbps or lower** | `AUDIO_BITRATE` | Default is `160k`; set `128k` to match X's guidance — X may re-encode or complain above it |
| ≥10 Mbps upload from the encoder | — | any VPS vastly exceeds this |

Practical notes:

- X recommends **CBR** (constant bitrate) rate control rather than VBR — the
  streamer's ffmpeg args pin bitrate accordingly, which also makes VPS egress
  predictable.
- Lofi streams are mostly static imagery — bitrate buys you nothing past clean
  gradients and film grain. `3500k` at 720p30 looks great and keeps monthly
  egress around 1.2 TB (see [VPS-SETUP.md](VPS-SETUP.md) for the math).
- If you see stuttering in X's preview but the streamer logs look clean, drop
  `VIDEO_BITRATE` before touching anything else.

## 6. 24/7 operation: how restarts interact with X broadcasts

The parts that matter for an always-on station:

- **Duration limits.** Media Studio Producer historically imposed *no* hard cap on
  broadcast length; X's Live Studio documentation cites a **24-hour maximum** per
  livestream. Separately, broadcasts *scheduled in advance* are capped at 6 hours,
  while broadcasts started immediately are not. Either way, X itself warns that
  very long broadcasts degrade: replays get flaky, the live page loads slowly.
- **The practical pattern: rotate broadcasts daily.** End the broadcast in Live
  Studio and immediately create a new one attached to the **same source** — your
  VPS keeps pushing the whole time, no `.env` change, no container restart. The
  new broadcast picks up the feed within seconds. This resets replay length,
  produces a fresh timeline post daily (which is good for reach anyway), and
  stays inside the 24h ceiling.
- **Encoder drops.** The streamer container retries forever with 5s backoff. A
  brief drop (container restart, network blip) typically resumes into the same
  broadcast — X holds the broadcast open for a short grace window when the feed
  disappears. A longer outage ends the broadcast; when the encoder comes back,
  the source shows live again and you create a new broadcast from it. **The
  stream key never changes** across any of this.
- **Automating rotation.** X's Live Studio has scheduling but no public "end +
  recreate broadcast" API as of mid-2026, so daily rotation is a ~60-second
  manual ritual — or a reason to use the Restream fallback below, which keeps a
  single ingest on your side.

## 7. Fallback: Restream.io (if you can't get Producer/Live Studio access)

If your account can't access Live Studio (no Premium, unsupported region, or the
rollout hasn't reached you), route through [Restream](https://restream.io):

1. Create a Restream account. Your VPS pushes to Restream's ingest instead of X:
   ```bash
   X_RTMP_URL=rtmp://live.restream.io/live
   X_STREAM_KEY=<your Restream stream key>
   ```
   (The var names stay the same — the streamer doesn't care who's on the other end.)
2. In Restream, **Channels → Add Channel → X** and authorize the app (native
   integration), or add a **Custom RTMP** channel with credentials from
   `studio.x.com` if you *do* have them. Note: the native X channel still
   requires your X account to be able to go live (Premium); Restream doesn't
   bypass X's eligibility — it bypasses the *Producer UI* and adds multistreaming.
3. Custom RTMP channels require a **paid Restream plan**; check their current
   plan limits on stream duration — 24/7 use realistically needs a paid tier.

Why bother: Restream lets you simulcast the same feed to YouTube/Twitch/Kick at
no extra encoding cost on your VPS, and their dashboard handles reconnect grace
windows so brief drops don't kill the X broadcast.

## 8. Troubleshooting

| Symptom | Check |
|---|---|
| Source never shows "receiving" | `docker compose logs streamer` — is ffmpeg connecting? Is `X_RTMP_URL` missing the `/x` app path or has a trailing slash? |
| Connects then drops every few seconds | Wrong/rotated stream key, or another encoder is pushing to the same source |
| Preview is video-only / audio-only | Icecast mount up? `./scripts/status.sh` shows listener + mount state |
| Broadcast ended overnight | Expected past ~24h — adopt the daily rotation pattern above |
| Account can't access studio.x.com | Premium lapsed, or Live Studio rollout hasn't reached the account — use the Restream path |

## Sources

- [Media Studio Producer — X Help Center](https://help.x.com/en/using-x/how-to-use-live-producer)
- [Live Studio — X Help Center](https://help.x.com/en/using-x/live-studio)
- [Media Studio Producer — X Business](https://business.x.com/en/products/media-studio/producer)
- [Restream: How to find your X stream key](https://restream.io/learn/platforms/how-to-find-x-stream-key/)
- [Restream: Stream to X](https://support.restream.io/en/articles/5594822-stream-to-x)
- [Restream: Best streaming settings for X](https://restream.io/integrations/twitter/best-streaming-settings-for-twitter-live/)
- [Socialive: Streaming to X Media Studio via RTMP](https://support.socialive.us/support/solutions/articles/67000686130-livestream-to-x-twitter-media-studio-via-rtmp)
- [Meld Studio: How to start streaming on X in 2026](https://meldstudio.co/blog/how-to-start-streaming-on-x-in-2026/)
- [X launches Live Studio (AlternativeTo, July 2026)](https://alternativeto.net/news/2026/7/x-launches-live-studio-a-new-live-streaming-tool-to-rival-youtube-and-twitch/)
- [X is making a fresh push for live video with new creator payouts (Engadget, July 2026)](https://www.engadget.com/2206527/x-push-for-live-video-creator-payouts/)
- [How to Live Stream on X — encoder settings (Vimeo blog)](https://vimeo.com/blog/post/stream-on-x)
