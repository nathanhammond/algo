#!/bin/sh
# Authorizes the test's SSH key (passed in TEST_SSH_PUBLIC_KEY), then boots systemd.
set -e
printf '%s\n' "$TEST_SSH_PUBLIC_KEY" > /home/algo/.ssh/authorized_keys
chown algo:algo /home/algo/.ssh/authorized_keys
chmod 0600 /home/algo/.ssh/authorized_keys
exec /sbin/init
