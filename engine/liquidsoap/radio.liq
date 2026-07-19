# LOFI 247 — playlist engine.
# Written for liquidsoap 2.4.x (pinned image: savonet/liquidsoap:v2.4.5).
#
# Responsibilities:
#   - randomized playlist of /music, reloaded whenever the directory changes
#   - smart (volume-aware) crossfade between tracks
#   - fallback chain: playlist -> ambient bed (if present) -> silence
#   - on every track change, atomically write /data/nowplaying.txt and
#     /data/nowplaying.json for the streamer overlay and the web player
#   - 320 kbps MP3 to icecast mount "radio"

# Runs as a dedicated non-root uid (compose user: "10000:10000"); the
# data-init service pre-owns /data so no root privileges are needed here.
settings.log.stdout := true
settings.log.level := 3

music_dir = "/music"
fallback_file = "/music/.fallback/ambient-fallback.mp3"
nowplaying_txt = "/data/nowplaying.txt"
nowplaying_json = "/data/nowplaying.json"

station_name = environment.get(default="LOFI 247", "STATION_NAME")
icecast_password = environment.get(default="", "ICECAST_SOURCE_PASSWORD")

if icecast_password == "" then
  log.severe(
    label="lofi247",
    "ICECAST_SOURCE_PASSWORD is empty; icecast will reject the source connection. Set it in .env."
  )
end

# --- metadata cleanup -------------------------------------------------------

# Collapse whitespace/newlines in a tag so the overlay stays on one line.
def clean_tag(s) =
  string.trim(string.replace(pattern="[\\r\\n\\t ]+", fun (_) -> " ", s))
end

# Make a filename presentable: drop the extension and any leading track
# number, turn separators into spaces.
def humanize(name) =
  base = path.remove_extension(name)
  base = string.replace(pattern="^[0-9]+[. _-]+", fun (_) -> "", base)
  base = string.replace(pattern="_", fun (_) -> " ", base)
  clean_tag(base)
end

# Derive display artist/title, falling back to the cleaned filename when
# tags are missing or messy.
def display_of(m) =
  artist = clean_tag(m["artist"])
  title = clean_tag(m["title"])
  filename = path.basename(m["filename"])
  if artist != "" and title != "" then
    {artist=artist, title=title, filename=filename}
  else
    base = humanize(filename)
    parts = string.split(separator=" - ", base)
    if list.length(parts) >= 2 then
      {
        artist=string.trim(list.hd(default="", parts)),
        title=string.trim(string.concat(separator=" - ", list.tl(parts))),
        filename=filename
      }
    elsif base != "" then
      {artist=station_name, title=base, filename=filename}
    else
      {artist=station_name, title="lofi radio", filename=filename}
    end
  end
end

# --- now-playing files ------------------------------------------------------

# file.write(atomic=true) writes to a temporary file and renames it into
# place, so readers never observe a partial write.
def write_now_playing(m) =
  d = display_of(m)
  file.write(data="#{d.artist} — #{d.title}\n", atomic=true, nowplaying_txt)
  file.write(
    data=
      json.stringify(
        compact=true, {artist=d.artist, title=d.title, filename=d.filename}
      ),
    atomic=true,
    nowplaying_json
  )
  log.important(label="nowplaying", "#{d.artist} — #{d.title}")
end

# Seed both files at startup so the streamer overlay has text before the
# first track's metadata arrives.
write_now_playing([])

# --- sources ----------------------------------------------------------------

# Shuffled playlist of everything under /music, reloaded whenever the
# directory contents change. check_next rejects dotted paths so the emergency
# bed in /music/.fallback/ never enters normal rotation (playlist() descends
# into dot-directories; verified against liquidsoap 2.4 file.ls behavior).
music =
  playlist(
    id="music",
    mode="randomize",
    reload_mode="watch",
    check_next=fun (r) -> not string.contains(substring="/.", request.filename(r)),
    music_dir
  )

# Volume-aware crossfade between tracks.
music = crossfade(duration=6.0, fade_in=2.0, fade_out=2.0, music)

# Emergency bed: looped ambient file if present, silence otherwise.
# Either way the stream must never die.
emergency =
  if file.exists(fallback_file) then
    log.important(label="lofi247", "Fallback bed available: #{fallback_file}")
    single(id="emergency_bed", fallback_file)
  else
    log.severe(
      label="lofi247",
      "No fallback bed at #{fallback_file}; silence will air if the music library is empty."
    )
    blank(id="emergency_silence")
  end

# track_sensitive=false: switch back to the playlist the moment it becomes
# available again instead of waiting for the emergency track to end.
radio = fallback(id="radio", track_sensitive=false, [music, emergency])

# Belt and suspenders: the output source must never fail.
radio = mksafe(radio)

# Write now-playing files on every metadata change (async: file I/O must not
# block the streaming clock).
radio.on_metadata(synchronous=false, write_now_playing)

# --- output -----------------------------------------------------------------

output.icecast(
  %mp3(bitrate=320, samplerate=44100, stereo),
  id="lofi247_out",
  host="icecast",
  port=8000,
  password=icecast_password,
  mount="radio",
  name=station_name,
  description="24/7 lofi radio",
  genre="Lo-fi",
  radio
)
