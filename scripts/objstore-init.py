#!/usr/bin/env python3
"""Initialise a single-node Garage (v2.5.0) through its admin API. Safe to run again.
Configuration comes from the environment. Secrets are never printed."""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

URL = os.environ["OBJSTORE_ADMIN_URL"].rstrip("/")
CA_FILE = os.environ.get("OBJSTORE_CA_FILE") or None
TOKEN = os.environ["ADMIN_TOKEN"]
KEY_ID = os.environ["ACCESS_KEY_ID"]
KEY_SECRET = os.environ["SECRET_ACCESS_KEY"]
BUCKET = os.environ.get("BUCKET", "pgbackrest")
ZONE = os.environ.get("ZONE", "dc1")
CAPACITY = int(os.environ.get("CAPACITY_BYTES", str(1024 ** 3)))
CTX = ssl.create_default_context(cafile=CA_FILE)


def scrub(text):
    for secret in (TOKEN, KEY_SECRET):
        text = text.replace(secret, "<redacted>")
    return text


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        URL + path, data=data, method=method,
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15, context=CTX) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        detail = scrub(err.read().decode(errors="replace"))[:300]
        raise RuntimeError("%s %s -> HTTP %s: %s" % (method, path, err.code, detail)) from None


def wait_for_admin_api(seconds=120):
    deadline = time.time() + seconds
    last = "no attempt"
    while time.time() < deadline:
        try:
            status = call("GET", "/v2/GetClusterStatus")
            if status and status.get("nodes"):
                return status
            last = "no nodes in status"
        except Exception as err:  # noqa: BLE001 - keep retrying, report the last error
            last = scrub(str(err))
            if "HTTP 401" in last or "HTTP 403" in last:
                raise
        time.sleep(2)
    raise RuntimeError("admin API not ready after %ss: %s" % (seconds, last))


def main():
    status = wait_for_admin_api()
    nodes = status["nodes"]
    if len(nodes) != 1:
        raise RuntimeError("expected exactly 1 node, found %d" % len(nodes))
    node = nodes[0]

    if node.get("role") is None:
        call("POST", "/v2/UpdateClusterLayout",
             {"roles": [{"id": node["id"], "zone": ZONE, "capacity": CAPACITY, "tags": []}]})
        call("POST", "/v2/ApplyClusterLayout", {"version": status["layoutVersion"] + 1})
        print("layout: role assigned and applied", flush=True)
    else:
        print("layout: role already assigned", flush=True)

    bucket_id = None
    for item in call("GET", "/v2/ListBuckets") or []:
        if BUCKET in (item.get("globalAliases") or []):
            bucket_id = item["id"]
    if bucket_id is None:
        bucket_id = call("POST", "/v2/CreateBucket", {"globalAlias": BUCKET})["id"]
        print("bucket: created", flush=True)
    else:
        print("bucket: already exists", flush=True)

    if any(item.get("id") == KEY_ID for item in call("GET", "/v2/ListKeys") or []):
        print("key: already imported", flush=True)
    else:
        call("POST", "/v2/ImportKey",
             {"accessKeyId": KEY_ID, "secretAccessKey": KEY_SECRET, "name": "pgbackrest"})
        print("key: imported", flush=True)

    call("POST", "/v2/AllowBucketKey",
         {"bucketId": bucket_id, "accessKeyId": KEY_ID, "permissions": {"read": True, "write": True}})
    print("permissions: read and write granted (idempotent)", flush=True)
    print("INIT OK", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # noqa: BLE001
        print("INIT FAILED: " + scrub(str(err)), file=sys.stderr, flush=True)
        sys.exit(1)
