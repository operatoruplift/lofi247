# VISUALS — Background Loop Production Guide

How to produce the animated background loops that play behind the LOFI 247
audio stream. The streamer container concatenates every `*.mp4` in `visuals/`
with FFmpeg's **concat demuxer**, composites the now-playing overlay on top,
and pushes the result to X via RTMP.

The concat demuxer is fast (no re-encode at play time) but strict: every file
must have an **identical stream layout and matching parameters**. One
off-spec clip can desync or kill the stream. That is why every clip goes
through `scripts/prep-visual.sh` before it lands in `visuals/`.

---

## 1. Clip specification (enforced by `scripts/prep-visual.sh`)

| Property     | Required value                     | Why                                                        |
|--------------|------------------------------------|------------------------------------------------------------|
| Container    | `.mp4` (faststart)                 | Streamer globs `*.mp4`; faststart = instant demux          |
| Video codec  | H.264 (libx264), yuv420p           | Universally decodable; concat needs one codec across clips |
| Resolution   | 1920x1080 exactly                  | Mixed resolutions break concat playback                    |
| Frame rate   | Constant 30 fps (CFR, `30/1`)      | VFR or mixed rates cause drift and stutter at clip joins   |
| Audio        | **None — no audio track at all**   | See below                                                  |
| Bitrate      | Similar across clips (CRF 20 ≈ 4–8 Mbps for animation) | Keeps the encoder's rate control stable at clip boundaries |
| Duration     | ≥ 1s (practically: 30–90s per clip) | Very short clips make the join points obvious              |

**About audio:** the broadcast audio always comes from Icecast — the streamer
never uses audio embedded in a clip, so any soundtrack in your source video is
discarded. But "ignored" is not good enough for the concat demuxer: it
requires every file to have the *same* streams, so a mix of with-audio and
without-audio clips is invalid. The rule is therefore **all clips carry zero
audio tracks**, and `prep-visual.sh` strips audio unconditionally (`-an`).

Note: clips are mastered at 1080p even though the default broadcast is
`STREAM_WIDTH x STREAM_HEIGHT` (1280x720). The streamer scales down at
composite time; mastering at 1080p means you can raise the output resolution
later without regenerating your library.

Normalize any source (Seedance render, screen capture, stock clip) with:

```bash
scripts/prep-visual.sh ~/Downloads/seedance-render.mp4 01-rainy-desk
# -> visuals/01-rainy-desk.mp4, then prints an ffprobe summary + PASS/FAIL
```

---

## 2. Seedance 2.0 workflow

Generate 10-second seamless-looping scenes with Seedance 2.0, then extend
them to 60s clips with the FFmpeg recipes in section 4. Every prompt follows
the same skeleton — static camera, loop phrasing, slow ambient motion only,
10s, 1080p, lofi anime aesthetic, no text or watermarks.

### Prompt templates (copy-paste ready)

**1. Rainy window study desk with cat**

> Static locked-off camera, seamless loop where the last frame matches the
> first frame. A cozy study desk at night beside a rain-streaked window; a
> sleeping cat curled next to a warm desk lamp, a notebook and steaming mug.
> Only slow ambient motion: rain droplets sliding down the glass, gentle
> steam rising from the mug, the cat's side rising and falling softly. Lofi
> anime illustration aesthetic, warm muted palette, soft painterly shading,
> subtle film grain. 10 seconds, 1080p. No text, no watermark, no camera
> movement, no people.

**2. Dusk rooftop cityscape**

> Static locked-off camera, seamless loop where the last frame matches the
> first frame. A rooftop view over a sprawling city at dusk, purple-orange
> gradient sky, scattered building windows glowing warm. Only slow ambient
> motion: a few windows flickering on, thin drifting clouds, faint blinking
> antenna lights. Lofi anime illustration aesthetic, muted twilight palette,
> soft atmospheric haze, subtle film grain. 10 seconds, 1080p. No text, no
> watermark, no camera movement, no people.

**3. Night train window**

> Static locked-off camera fixed on a train window seat, seamless loop where
> the last frame matches the first frame. Interior of a quiet night train; a
> window showing distant city lights and telephone poles drifting past in a
> repeating rhythm, soft cabin reflection on the glass. Only slow ambient
> motion: passing lights, gentle carriage sway, faint window reflections.
> Lofi anime illustration aesthetic, deep blue night palette with warm
> interior accents, subtle film grain. 10 seconds, 1080p. No text, no
> watermark, no people.

**4. Cozy cabin snowfall**

> Static locked-off camera, seamless loop where the last frame matches the
> first frame. A wooden cabin interior at night, a big window showing slow
> steady snowfall over pine trees, a fireplace glowing at the edge of frame.
> Only slow ambient motion: falling snow, flickering firelight, gentle smoke
> from a distant chimney. Lofi anime illustration aesthetic, warm amber
> interior against cool blue exterior, subtle film grain. 10 seconds, 1080p.
> No text, no watermark, no camera movement, no people.

**5. Neon alley drizzle**

> Static locked-off camera, seamless loop where the last frame matches the
> first frame. A narrow city alley at night in light drizzle, wet asphalt
> reflecting pink and cyan neon signs, steam venting from a grate. Only slow
> ambient motion: drizzle falling, neon reflections shimmering in puddles,
> steam drifting. Lofi anime illustration aesthetic, saturated neon accents
> over a dark muted base, subtle film grain. 10 seconds, 1080p. No text on
> signs (abstract glyph shapes only), no watermark, no camera movement, no
> people.

**6. Plants and record player at golden hour**

> Static locked-off camera, seamless loop where the last frame matches the
> first frame. A sunlit room corner at golden hour: a spinning vinyl record
> on a turntable, monstera and hanging plants, dust motes in a warm light
> beam. Only slow ambient motion: the record rotating, dust motes drifting,
> leaves trembling faintly. Lofi anime illustration aesthetic, warm golden
> palette, soft bloom, subtle film grain. 10 seconds, 1080p. No text, no
> watermark, no camera movement, no people.

**7. Late-night ramen counter**

> Static locked-off camera, seamless loop where the last frame matches the
> first frame. An empty late-night ramen shop counter, a steaming bowl under
> a single hanging lamp, paper lanterns glowing softly in the background.
> Only slow ambient motion: rising steam, gently swaying lantern, faint
> flicker of the lamp. Lofi anime illustration aesthetic, warm lamplight
> against deep shadows, subtle film grain. 10 seconds, 1080p. No text on
> lanterns or menus (abstract shapes only), no watermark, no camera
> movement, no people.

**8. Moonlit koi pond**

> Static locked-off camera looking down at a garden koi pond under
> moonlight, seamless loop where the last frame matches the first frame.
> Lily pads, a stone lantern reflection, two koi gliding in a slow circular
> path that returns to its start. Only slow ambient motion: rippling water,
> drifting koi, a falling leaf landing softly. Lofi anime illustration
> aesthetic, silver-blue night palette with warm lantern accent, subtle film
> grain. 10 seconds, 1080p. No text, no watermark, no camera movement, no
> people.

### Prompt-generator meta-prompt

Paste this into ChatGPT (or any LLM) to mass-produce more scene prompts in
the exact same format:

```text
You are a prompt writer for Seedance 2.0, a text-to-video model. Generate N
new scene prompts for seamless-looping lofi radio background videos. Every
prompt MUST follow this exact structural template:

"Static locked-off camera, seamless loop where the last frame matches the
first frame. [SCENE: one cozy, atmospheric location described in 1-2
sentences]. Only slow ambient motion: [2-4 specific subtle motion elements
that can loop naturally, e.g. rain, steam, flicker, drift]. Lofi anime
illustration aesthetic, [PALETTE: one mood-appropriate color description],
subtle film grain. 10 seconds, 1080p. No text, no watermark, no camera
movement, no people."

Rules:
- Scenes must feel calm and loop-friendly: no narrative events, no fast
  motion, no humans or animals walking through frame (a sleeping/idle animal
  is fine).
- Motion elements must be cyclical or continuous (rain, steam, flicker,
  drift, rotation) so the loop point is invisible.
- Vary settings across: urban night, nature, interiors, seasons, weather,
  time of day. No two prompts in the same location category twice in a row.
- If a scene would naturally contain signage or books, explicitly convert
  them to "abstract shapes only, no legible text".
- Output as a numbered list, one prompt per item, no commentary.

Generate N = 10.
```

---

## 3. From Seedance render to broadcast-ready clip

The pipeline for each scene:

1. Generate the 10s scene in Seedance 2.0 (prompts above).
2. If the loop point is visible, fix it with the crossfade trick (recipe A).
3. Extend the short loop to ~60s (recipe B).
4. Optionally apply the uniform grade so mixed sources match (recipe C).
5. **Always finish with `scripts/prep-visual.sh`** — it is the only step
   that guarantees the concat spec, whatever recipes B/C produced.
6. Verify with ffprobe (recipe D) or trust the script's built-in PASS check.

---

## 4. FFmpeg recipes

All verified on FFmpeg 8.1.

### A. Make an imperfect loop seamless (xfade crossfade-tail trick)

Seedance loops are usually close but not exact. The fix: cut the first `F`
seconds off the head, then crossfade the tail into that removed head
segment. The output ends on the exact frame it starts with, so the loop
point disappears.

For a clip of duration `T` seconds and fade `F` seconds, the xfade offset is
`T - 2F` and the output duration is `T - F`. With `T=10`, `F=1`:

```bash
ffmpeg -i scene.mp4 -filter_complex \
  "[0:v]split[a][b]; \
   [a]trim=start=1,setpts=PTS-STARTPTS[main]; \
   [b]trim=duration=1,setpts=PTS-STARTPTS[head]; \
   [main][head]xfade=transition=fade:duration=1:offset=8[v]" \
  -map "[v]" -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p \
  -movflags +faststart scene-loop.mp4
```

Result: a 9s clip that loops invisibly. If the seam is still visible, raise
`F` to 1.5–2s (recompute `offset = T - 2F` and both `trim` values to `F`).

### B. Extend a 10s loop to a ~60s clip

Concatenate the loop back-to-back with stream copy (no quality loss, fast).
`-stream_loop 5` plays the input 6 times total: 6 x 10s = 60s. For the 9s
output of recipe A, use `-stream_loop 6` (7 x 9s = 63s — close enough).

```bash
ffmpeg -stream_loop 5 -i scene-loop.mp4 -c copy -movflags +faststart scene-60s.mp4
```

Longer per-clip durations mean fewer concat joins per hour on the live
stream. 60–90s per clip is the sweet spot.

### C. Uniform grade: film grain + slight vignette

Apply the same subtle grade to every clip so material from different
Seedance runs (or mixed sources) feels like one channel:

```bash
ffmpeg -i scene-60s.mp4 \
  -vf "noise=alls=7:allf=t+u,vignette=angle=PI/5,eq=saturation=0.9:gamma=0.98" \
  -c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p \
  -movflags +faststart scene-graded.mp4
```

- `noise=alls=7:allf=t+u` — temporal, uniform film grain (raise `alls` to 10
  for a heavier look; keep the value identical across all clips)
- `vignette=angle=PI/5` — gentle corner falloff
- `eq=saturation=0.9:gamma=0.98` — slight desaturation for the lofi mood

Then run `scripts/prep-visual.sh scene-graded.mp4 01-rainy-desk` as the
final step.

### D. Verify a clip's specs with ffprobe

```bash
# Video stream: expect h264 / 1920x1080 / yuv420p / 30/1 on both rate fields
ffprobe -v error -select_streams v:0 -show_entries \
  stream=codec_name,width,height,pix_fmt,r_frame_rate,avg_frame_rate \
  -show_entries format=duration,bit_rate \
  -of default=noprint_wrappers=1 visuals/01-rainy-desk.mp4

# Audio streams: this MUST print nothing
ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 \
  visuals/01-rainy-desk.mp4
```

`r_frame_rate` and `avg_frame_rate` must both read `30/1` — if they differ,
the clip is VFR and must be re-run through `prep-visual.sh`.

---

## 5. Playlist behavior and curation

### Ordering

The streamer plays clips **sorted alphabetically by filename, then loops the
whole sequence forever**. Control the order with a numeric prefix:

```text
visuals/
├── 01-dusk-rooftop.mp4
├── 02-rainy-desk.mp4
├── 03-night-train.mp4
├── 04-neon-alley.mp4
└── 05-koi-pond.mp4
```

Convention: `NN-short-slug.mp4`, two-digit prefix, lowercase kebab-case.
Leave gaps (01, 02, 03 … not 1, 2, 3) so inserting a clip later doesn't
force a mass rename — and note that `10` sorts before `2`, which is exactly
why the two-digit prefix matters.

### Day / night curation

Keep two curated sets and swap which one occupies `visuals/`:

```bash
mkdir -p visuals-day visuals-night   # library folders, not read by the streamer

# Evening switchover:
rm -f visuals/*.mp4
cp visuals-night/*.mp4 visuals/
docker compose restart streamer
```

This is entirely independent of Liquidsoap — audio never blips during the
swap. The streamer only reads the visuals directory when it (re)starts, so
**changing files requires `docker compose restart streamer`** to take
effect. The restart causes a brief video hiccup on the X stream; schedule
swaps at natural moments. (Automate with two cron entries on the VPS if
desired.)

### If `visuals/` is empty

The streamer generates a procedural fallback loop (animated dark gradient +
grain) at startup and streams that instead — the channel never dies for lack
of visuals. Drop real clips in and restart the streamer whenever ready.

---

## 6. Pre-flight checklist for a new clip

- [ ] Generated with a static camera and loop-friendly ambient motion
- [ ] Loop point invisible (recipe A applied if needed)
- [ ] Extended to 60–90s (recipe B)
- [ ] Uniform grade applied with the same settings as the rest of the library (recipe C)
- [ ] Passed through `scripts/prep-visual.sh` (mandatory, final step)
- [ ] Script printed `PASS` — h264 / yuv420p / 1920x1080 / 30fps CFR / no audio
- [ ] Named `NN-slug.mp4` so it sorts where you want it
- [ ] `docker compose restart streamer` after the file lands in `visuals/`
