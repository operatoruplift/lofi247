# LOFI 247 streamer — ffmpeg compositor that pushes the channel to X via RTMP.
# alpine 3.22 ships ffmpeg 6.1 built with libx264 and libfreetype (drawtext).
FROM alpine:3.22

# font-dejavu covers Latin; font-noto-cjk adds Japanese/Korean/Chinese glyphs so
# CJK artist names in the now-playing overlay don't render as tofu boxes.
RUN apk add --no-cache \
    bash \
    curl \
    ffmpeg \
    font-dejavu \
    font-noto-cjk

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
