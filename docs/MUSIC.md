# Music: Sourcing, Licensing, and Ingest

How tracks get into the LOFI 247 rotation, and — first — why you must have the
rights to every one of them.

```
acquire (any legal source) -> ./downloads or anywhere
        -> verify rights -> tag ID3 metadata -> scripts/ingest-music.sh
        -> ./music -> liquidsoap picks it up automatically (watch mode)
```

---

## 1. Licensing comes first

Streaming music on a public X broadcast is a **public performance and
rebroadcast** of both the recording and the underlying composition. "I bought
the album", "it's on Soulseek", or "everyone does it" is not a license. For
every track on air you need permission from whoever controls the rights —
via a direct license, a Creative Commons or royalty-free license that covers
broadcast/commercial use, or because you made the track yourself.

What happens when you stream tracks you don't have rights to — not
hypothetically, routinely:

- **DMCA takedowns.** Rights holders and their automated agents scan live
  platforms. Your broadcast gets cut mid-stream.
- **Copyright strikes.** Repeat notices accumulate against your account.
- **X account suspension.** Platforms terminate repeat infringers — it is a
  legal safe-harbor requirement for them, not a judgment call. A 24/7 channel
  is maximally exposed because it is always on and easy to sample.

A 24/7 station only works if the library is clean. Build it clean from track
one, and keep a record (email, receipt, license text, generation-account
screenshot) of *why* you have rights to each file.

---

## 2. Legal sourcing options

### a) Commission or license directly from lofi artists and netlabels

The best-sounding and most defensible option. Lofi producers on Bandcamp,
SoundCloud, and netlabels (many run open submission inboxes) frequently
license tracks to radio channels for modest flat fees or exposure deals —
this is exactly how the big YouTube lofi channels operate.

What to ask for, in writing (email is fine):

- A **non-exclusive license to publicly perform and rebroadcast** the track
  on internet radio and live social streams (name the channel and platform).
- Whether the grant is perpetual or time-limited, and whether the channel
  being monetized later changes anything.
- How they want to be **credited** (see attribution below — credit is cheap,
  do it even when not required).

Keep every reply. That folder of emails is your license library.

### b) Royalty-free and Creative Commons catalogs

Free, but the license is **per track** — never assume a whole catalog shares
one license.

- **Pixabay Music** (pixabay.com/music) — Pixabay Content License allows
  commercial use with no attribution required. Broad lofi/chillhop selection.
- **Free Music Archive** (freemusicarchive.org) — mixed CC licenses. Check
  each track: **CC-BY** requires attribution; **CC-BY-NC** excludes
  commercial use (risky for a channel you might ever monetize); **-ND**
  variants forbid derivatives, which matters if you edit or crossfade
  destructively. When in doubt, skip the track.
- **ccMixter** (ccmixter.org) — remix community, heavy on CC-BY. Same
  per-track diligence.
- **Incompetech** (incompetech.com) — Kevin MacLeod's catalog: free with
  CC-BY attribution, or a paid license if you don't want to attribute.

**How to attribute on a live stream** (CC-BY's requirement is "reasonable to
the medium" — you cannot put a caption on a radio signal, so):

- Maintain a **public tracklist/credits document** (a pinned X post, a thread,
  or a linked page) listing artist, track, source, and license for every
  CC-BY track in rotation. Update it when you ingest.
- Put a **rotating credits line in the X bio or pinned post**: "Music by
  <artists> under CC-BY — full credits: <link>".
- The now-playing overlay already shows `Artist — Title` on the video for
  every track, which is genuine on-screen credit; treat the pinned
  tracklist as the canonical attribution.

### c) AI-generated music

Viable for filling a 24/7 rotation, but the terms move fast — **verify the
current terms yourself before relying on this** (status as of July 2026):

- **Suno** — commercial-use rights require a **paid plan (Pro or Premier)**.
  Under the terms revised after the Warner Music partnership, Suno remains
  the "author" of the audio and you receive a **perpetual commercial-use
  license** rather than ownership. Tracks generated on the **free tier are
  non-commercial**, and upgrading later does **not** retroactively license
  them — regenerate under the paid plan. Verified July 2026 against Suno's
  "What rights do I have with a paid subscription?" article
  (help.suno.com/en/articles/9601665) and the Rights & Ownership knowledge
  base (help.suno.com/en/categories/550145).
- **Udio** — following the October 29, 2025 Universal Music Group settlement
  and joint venture, Udio **disabled downloads** and moved to an in-platform
  "walled garden": new generations cannot be exported (a one-off 48-hour
  download window in Nov 2025 aside — don't count on a repeat), which makes
  Udio **currently unusable for this pipeline** regardless of subscription
  tier (verified July 2026). Re-check their terms and pricing pages if this
  changes.
- Either way: keep your subscription receipts and the generation history in
  your account as proof of license, and note that raw AI output may not be
  copyrightable at all (US Copyright Office requires human authorship) —
  you have a license to broadcast it, which is what matters here.

### d) Your own productions

The cleanest option: you hold the rights outright. One caveat — sample packs
and loop libraries (Splice, etc.) come with their own licenses; standard
subscription terms generally allow commercial release of derivative works,
but check before building tracks around third-party loops.

---

## 3. slskd — the optional "acquire" profile

The compose file includes [slskd](https://github.com/slskd/slskd), a
Soulseek client with a web UI, behind the `acquire` profile. It is **off by
default** and is **never connected to the broadcast**: `./downloads` is not
mounted into liquidsoap, so nothing it fetches can reach the air without a
human running the ingest script.

**Use it only for content you have the rights to broadcast** — e.g. pulling
files an artist has licensed to you, retrieving CC-licensed releases, or
recovering your own masters. Soulseek is a peer-to-peer network and most of
what circulates on it is commercial copyrighted music; downloading that does
not create rights, and streaming it triggers everything in section 1.

Usage:

```bash
# 1. Set credentials in .env (see .env.example):
#    SLSKD_USERNAME / SLSKD_PASSWORD          -> web UI login
#    SLSKD_SLSK_USERNAME / SLSKD_SLSK_PASSWORD -> Soulseek network account
#    SLSKD_PASSWORD is MANDATORY and must be strong — this UI holds your
#    Soulseek credentials.

# 2. Start it (only starts with the profile flag):
docker compose --profile acquire up -d slskd

# 3. Open the web UI. It is bound to localhost on the VPS (never exposed
#    to the internet — see docs/VPS-SETUP.md section 4), so tunnel in:
#      ssh -L 5030:localhost:5030 lofi@your-vps
#    then open http://localhost:5030 locally and log in.

# 4. Search, download. Files land in ./downloads on the host.

# 5. When you're done acquiring, shut it off:
docker compose --profile acquire stop slskd
```

Downloads then go through the same curation as everything else: verify
rights, tag, ingest. **Nothing goes from `./downloads` to air directly.**

---

## 4. Ingest flow

### Step 1 — verify rights

Per section 1. If you can't say *which* license covers a file, it doesn't go
in. Record the answer in your credits/rights log.

### Step 2 — tag metadata (this drives the on-air overlay)

The stream's now-playing overlay and the web player both read **ID3
artist/title tags** — liquidsoap writes `Artist — Title` to the video
overlay and `nowplaying.json` on every track change. Untagged files show up
on air as filenames. Fix tags **before** ingesting:

- **MusicBrainz Picard** (free, cross-platform, auto-lookup)
- **Mp3tag** (Windows/macOS, fast batch editing)
- **Kid3** (free, cross-platform, handles every format the ingester accepts)

Set at minimum `artist` and `title`. Ingest preserves all text tags
(`-map_metadata 0`); embedded cover art is dropped (the stream has its own
visuals).

### Step 3 — run the ingest script

```bash
# one or more files; mp3, flac, wav, m4a, ogg
scripts/ingest-music.sh downloads/artist-track.flac downloads/*.mp3
```

For each file it runs **two-pass ffmpeg loudnorm** (measure, then apply
linear normalization to **-14 LUFS integrated, -1.5 dBTP true peak, LRA 11**)
and writes a **320 kbps MP3** into `./music`, atomically (temp file, then
rename), preserving tags. Files whose output already exists in `./music` are
skipped, so re-running on a whole directory is safe. A summary prints at the
end; the script exits non-zero if any file failed.

To ingest into a different directory (e.g. for a test listen before
committing to rotation): `MUSIC_DIR=/tmp/audition scripts/ingest-music.sh
file.mp3` — anything except the real `./music`.

### Step 4 — nothing else

Liquidsoap runs its playlist in **watch mode**: it notices new files in
`/music` automatically. No restart, no reload command. The track enters
rotation on its own.

---

## 5. Why loudness normalization (-14 LUFS)

A 24/7 stream plays files from many sources — Bandcamp masters, CC archives,
AI generations — whose loudness varies by 15+ dB. Without normalization,
listeners get blasted by one track and strain to hear the next, and the fixed
AAC/MP3 encoding chain has to handle unpredictable levels.

The targets the ingester applies:

- **-14 LUFS integrated** — the de facto streaming standard (Spotify,
  YouTube, Amazon normalize to roughly this level). Loud enough to sit well
  on phone speakers, quiet enough to preserve the dynamics lofi depends on.
- **-1.5 dBTP true peak** — headroom so the lossy re-encode to the stream
  bitrate doesn't clip on inter-sample peaks.
- **LRA 11** — keeps loudness range consistent without crushing the material.

Because every file is normalized at ingest (two-pass, so it's a clean linear
gain change whenever possible — no pumping), the live chain never has to do
dynamic loudness correction, and track-to-track transitions stay seamless.
