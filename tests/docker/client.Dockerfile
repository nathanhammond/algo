# A WireGuard client used by the tests and tests/perf.sh.
FROM ubuntu:26.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      wireguard-tools iproute2 iptables dnsutils curl iputils-ping ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
