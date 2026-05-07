# tv-bridge — minimal image with adb + python3 stdlib HTTP server.
# Runtime needs: adb client (talks to TV on LAN port 5555), python3.
# No Companion-side dependencies, talks only to the TV's IP.

FROM debian:bookworm-slim

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        android-sdk-platform-tools \
        python3 \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Persist adb pairing key under a stable HOME so a mounted PVC keeps
# it across pod restarts.
ENV HOME=/data
ENV ANDROID_HOME=/data
ENV LISTEN_ADDR=0.0.0.0:9990

WORKDIR /app
COPY bridge.py /app/bridge.py

RUN useradd --system --uid 10001 --home-dir /data --shell /bin/false bridge \
 && mkdir -p /data \
 && chown -R bridge:bridge /data /app
USER bridge

EXPOSE 9990
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:9990/healthz', timeout=3).read()" || exit 1

CMD ["python3", "/app/bridge.py"]
