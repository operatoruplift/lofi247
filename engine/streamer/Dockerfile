# LOFI 247 streamer — ffmpeg compositor that pushes the channel to X via RTMP.
# alpine 3.22 ships ffmpeg 6.1 built with libx264 and libfreetype (drawtext).
FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    curl \
    ffmpeg \
    font-dejavu

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
