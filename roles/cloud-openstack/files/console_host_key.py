"""Prints the SSH host key a new server wrote to its console log.

files/cloud-init/base.yml writes it as one line, "ALGO-SSH-HOST-KEY ssh-ed25519 <base64>".
Usage: console_host_key.py SERVER_ID, with OpenStack credentials in the environment.
Exit status: 0 printed the key, 1 it is not in the log yet, 2 the log is not usable.
"""
import base64
import binascii
import re
import sys

import openstack

LINE = re.compile(r"^ALGO-SSH-HOST-KEY (ssh-ed25519 [A-Za-z0-9+/]+={0,2})\r?$", re.MULTILINE)
# An ed25519 public key blob: a length-prefixed "ssh-ed25519", then a length-prefixed 32-byte key
BLOB_PREFIX = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"

conn = openstack.connect()
log = conn.compute.get_server_console_output(sys.argv[1])["output"] or ""
keys = set(LINE.findall(log))
if not keys:
    print("The server has not written its SSH host key to its console yet.", file=sys.stderr)
    sys.exit(1)
if len(keys) > 1:
    print("The console log shows more than one SSH host key; not trusting any of them.", file=sys.stderr)
    sys.exit(2)
key = keys.pop()
try:
    blob = base64.b64decode(key.split()[1], validate=True)
except binascii.Error:
    blob = b""
if len(blob) != len(BLOB_PREFIX) + 32 or not blob.startswith(BLOB_PREFIX):
    print("The console log's SSH host key is not a valid ed25519 key.", file=sys.stderr)
    sys.exit(2)
print(key)
