#!/bin/sh
# Authorizes the test's SSH key (passed in TEST_SSH_PUBLIC_KEY), moves sshd to
# TEST_SSH_PORT (each Ubuntu version's suite has its own), then boots systemd.
set -e
sed -i "s/^Port .*/Port ${TEST_SSH_PORT:-4160}/" /etc/ssh/sshd_config
printf '%s\n' "$TEST_SSH_PUBLIC_KEY" > /home/algo/.ssh/authorized_keys
chown algo:algo /home/algo/.ssh/authorized_keys
chmod 0600 /home/algo/.ssh/authorized_keys
exec /sbin/init
