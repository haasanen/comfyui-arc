#!/usr/bin/env python3
"""Model provisioning for comfyui-arc — single source of truth.

Model sets live in model_sets.json (set name -> {files: {relpath: url}}).
Every file in a set must be verified for the 16 GB A770 before it ships.

Two ways in, both operator-free from ComfyUI's point of view:
  CLI   : provision.py fetch a,b | list | serve
  HTTP  : provision.py serve  (port $PROVISIONER_PORT, default 8189)
          GET    /sets    -> {"available":[...], "installed":{name:{files,bytes}}}
          GET    /status  -> {"busy":bool,"current":name|null,"log_tail":[...]}
          POST   /models  {"set":"name"} -> 202 started | 409 busy | 400 unknown
          DELETE /models?set=name        -> remove that set's files

Design notes:
  - HTTP API exists because the agent driving ComfyUI has only LAN HTTP
    (no docker socket, no compose) — model control must not require the
    human as hands. Keyless, LAN-only, matching the strata convention.
  - Downloads are resumable (curl -C - into .part, rename on success);
    a set counts as installed when its first listed file exists.
  - One job at a time; refuse delete while busy; refuse path escape
    (no absolute paths / "..").
  - New model files appear in ComfyUI's list without a restart
    (its file-list cache has a short TTL).
"""
import json
import os
import subprocess
import sys
import threading
import collections
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
SETS_PATH = os.environ.get("PROVISIONER_SETS", os.path.join(HERE, "model_sets.json"))
MODELS_DIR = os.environ.get("PROVISIONER_MODELS_DIR", "/models")
PORT = int(os.environ.get("PROVISIONER_PORT", "8189"))

_lock = threading.Lock()
_state = {"busy": False, "current": None}
_log = collections.deque(maxlen=200)


def sets():
    with open(SETS_PATH) as f:
        return json.load(f)


def safe_join(rel):
    if os.path.isabs(rel) or ".." in rel.split("/"):
        raise ValueError(f"unsafe path in set: {rel}")
    return os.path.join(MODELS_DIR, rel)


def set_info(name):
    s = sets()[name]
    files = []
    total = 0
    installed = True
    unsafe = False
    for rel in s["files"]:
        try:
            p = safe_join(rel)
        except ValueError:
            unsafe = True
            installed = False
            continue
        if os.path.exists(p):
            sz = os.path.getsize(p)
            total += sz
            files.append({"path": rel, "bytes": sz})
        else:
            installed = False
    info = {"installed": installed, "files": files, "bytes": total}
    if unsafe:
        info["error"] = "set contains unsafe path; fix model_sets.json"
    return info


def log(line):
    _log.append(line)
    print(f"[provisioner] {line}", flush=True)


def fetch_set(name):
    s = sets()[name]
    for rel, url in s["files"].items():
        try:
            dest = safe_join(rel)
        except ValueError as e:
            log(f"{name}: REJECTED {rel}: {e}")
            return False
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            log(f"{name}: {rel} present, skip")
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        part = dest + ".part"
        log(f"{name}: fetching {rel}")
        r = subprocess.run(
            ["curl", "-fsSL", "--retry", "5", "-C", "-", "-o", part, url],
            capture_output=True, text=True)
        if r.returncode != 0:
            log(f"{name}: FAILED {rel}: {r.stderr.strip()[:300]}")
            return False
        os.replace(part, dest)
        log(f"{name}: done {rel} ({os.path.getsize(dest)} bytes)")
    return True


def fetch_worker(name):
    try:
        ok = fetch_set(name)
    except Exception as e:  # never wedge busy
        ok = False
        log(f"{name}: EXCEPTION {e}")
    finally:
        with _lock:
            _state["busy"] = False
            _state["current"] = None
    log(f"{name}: {'complete' if ok else 'FAILED'}")


def start_fetch(name):
    if name not in sets():
        return "unknown", 400
    with _lock:
        if _state["busy"]:
            return f"busy: {_state['current']}", 409
        _state["busy"] = True
        _state["current"] = name
    threading.Thread(target=fetch_worker, args=(name,), daemon=True).start()
    return f"started: {name}", 202


def delete_set(name):
    if name not in sets():
        return "unknown", 400
    with _lock:
        if _state["busy"]:
            return f"busy: {_state['current']}", 409
    removed = []
    for rel in sets()[name]["files"]:
        try:
            p = safe_join(rel)
        except ValueError:
            continue  # never delete outside the models dir
        if os.path.exists(p):
            os.remove(p)
            removed.append(rel)
    log(f"{name}: deleted {len(removed)} file(s)")
    return f"deleted: {removed}", 200


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/sets":
            d = sets()
            self._send(200, {"available": sorted(d),
                             "installed": {n: set_info(n) for n in d}})
        elif path == "/status":
            with _lock:
                st = dict(_state)
            st["log_tail"] = list(_log)
            self._send(200, st)
        else:
            self._send(404, {"error": "use /sets, /status, /models"})

    def do_POST(self):
        if urlparse(self.path).path != "/models":
            self._send(404, {"error": "use POST /models {\"set\": name}"})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            self._send(400, {"error": "bad json"})
            return
        msg, code = start_fetch(str(payload.get("set", "")))
        self._send(code, {"status": msg})

    def do_DELETE(self):
        u = urlparse(self.path)
        if u.path != "/models":
            self._send(404, {"error": "use DELETE /models?set=name"})
            return
        name = (parse_qs(u.query).get("set") or [""])[0]
        msg, code = delete_set(name)
        self._send(code, {"status": msg})

    def log_message(self, format, *args):  # noqa: A002 - keep base signature
        pass  # keep stdout for provisioner logs only


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "list"
    if cmd == "list":
        d = sets()
        for n in d:
            info = set_info(n)
            print(f"{n}: {'installed' if info['installed'] else 'not installed'} "
                  f"({info['bytes']} bytes)")
    elif cmd == "fetch":
        rc = 0
        for name in argv[2].split(","):
            name = name.strip()
            if not name or name in ("0", "none"):
                continue
            if not fetch_set(name):
                rc = 1
        sys.exit(rc)
    elif cmd == "serve":
        log(f"provisioner on :{PORT}, models={MODELS_DIR}, "
            f"sets={sorted(sets())}")
        ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
    else:
        print(f"usage: provision.py [list|fetch a,b|serve]", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
