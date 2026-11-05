# An Ubuntu server for tests/docker.sh, with what Algo expects from a cloud image:
# systemd, SSH with sudo for the algo user, Python for Ansible, systemd-resolved,
# udev (systemd-networkd leaves links unconfigured without it, and Algo puts the
# DNS address on lo through networkd), and rsyslog and logrotate (which the
# privacy role configures).
ARG UBUNTU_VERSION=26.04
FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus openssh-server sudo python3 python3-apt iproute2 \
      systemd-resolved udev rsyslog logrotate \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# Docker images refuse to start services on package install; a VM does not
RUN rm -f /usr/sbin/policy-rc.d
# Docker, not systemd-networkd, configures eth0, so networkd never reports the
# network online and this unit always fails here (on a VM, netplan hands the NIC
# to networkd)
RUN systemctl mask systemd-networkd-wait-online.service
# The user Algo's cloud-init creates (files/cloud-init/base.yml), with SSH on port 4160
RUN useradd --create-home --shell /bin/bash --user-group algo \
 && echo 'algo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/algo && chmod 0440 /etc/sudoers.d/algo \
 && install -d -m 0700 -o algo -g algo /home/algo/.ssh
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/sbin/entrypoint.sh
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
