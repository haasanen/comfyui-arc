#!/usr/bin/env python3
"""Model provisioning for comfyui-arc — single source of truth, agent-owned.

Contract (owner, 2026-10-25): the image assumes NO models. The container
never fetches anything by itself. The agent driving ComfyUI controls the
model data entirely over this HTTP API: add set definitions, fetch, delete,
swap. Image updates go through the owner's deploy gate; model management
does not.

Registry lives on the models VOLUME at $MODELS_DIR/.provisioner/sets.json:
  - image model_sets.json = seed defaults, applied as a base layer;
  - volume registry overrides/removes them and survives image updates, so
    the agent's model decisions outlive redeploys.

API (keyless, LAN-only — strata convention):
  GET    /sets                 -> {"available":[...], "installed":{...}}
  GET    /status               -> {"busy","current","log_tail"}
  POST   /models {"set":name}  -> fetch 202 | 409 busy | 400 unknown
  DELETE /models?set=name      -> delete that set's files
  PUT    /sets/<name>          -> {"files":{"relpath":"https://..."}} add/override
  DELETE /sets/<name>          -> remove a definition (image sets get a
                                  removed-marker so image upgrades stay clean)

URL policy: https only, host allowlist = huggingface.co (the agent verifies
exact URLs/sizes/VRAM fit BEFORE registering; unverified URLs must not
enter the registry). Downloads resumable (curl -C -); one job at a time;
no absolute paths or ".."; no deletes outside the models dir.
New model files show up in ComfyUI's list without restart (short cache TTL);
workflows reference models by filename at run time, so swaps are per-run.
"""
import json
import os
import re
import subprocess
import sys
import threading
import collections
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
IMAGE_SETS = os.environ.get("PROVISIONER_SETS", os.path.join(HERE, "model_sets.json"))
MODELS_DIR = os.environ.get("PROVISIONER_MODELS_DIR", "/models")
REGISTRY = os.path.join(MODELS_DIR, ".provisioner", "sets.json")
PORT = int(os.environ.get("PROVISIONER_PORT", "8189"))
ALLOWED_HOSTS = {"huggingface.co"}
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")

_lock = threading.Lock()
_state = {"busy": False, "current": None}
_log = collections.deque(maxlen=200)


def image_sets():
    with open(IMAGE_SETS) as f:
        return json.load(f)


def volume_sets():
    try:
        with open(REGISTRY) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError:
        log("WARN volume registry unreadable, ignoring")
        return {}


def sets():
    live = dict(image_sets())
    for name, spec in volume_sets().items():
        if spec.get("removed"):
            live.pop(name, None)
        else:
            live[name] = spec
    return live


def save_volume(entry=None, drop=None):
    v = volume_sets()
    if drop:
        if drop in image_sets():
            v[drop] = {"removed": True}   # marker: beats future image upgrades
        else:
            v.pop(drop, None)
    if entry:
        name, spec = entry
        v[name] = spec
    os.makedirs(os.path.dirname(REGISTRY), exist_ok=True)
    tmp = REGISTRY + ".tmp"
    with open(tmp, "w") as f:
        json.dump(v, f, indent=1, sort_keys=True)
    os.replace(tmp, REGISTRY)


def safe_join(rel):
    if os.path.isabs(rel) or ".." in rel.split("/"):
        raise ValueError(f"unsafe path in set: {rel}")
    return os.path.join(MODELS_DIR, rel)


def valid_spec(spec):
    if not isinstance(spec, dict) or not isinstance(spec.get("files"), dict) \
            or not spec["files"]:
        return "spec must be {\"files\": {relpath: url}}"
    for rel, url in spec["files"].items():
        try:
            safe_join(rel)
        except ValueError as e:
            return str(e)
        u = urlparse(str(url))
        if u.scheme != "https" or u.netloc not in ALLOWED_HOSTS:
            return f"url must be https and host in {sorted(ALLOWED_HOSTS)}: {url}"
    return None


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
        info["error"] = "set contains unsafe path; fix the definition"
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


def delete_models(name):
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

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return None

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
        payload = self._body()
        if payload is None:
            self._send(400, {"error": "bad json"})
            return
        msg, code = start_fetch(str(payload.get("set", "")))
        self._send(code, {"status": msg})

    def do_PUT(self):
        u = urlparse(self.path)
        if not u.path.startswith("/sets/"):
            self._send(404, {"error": "use PUT /sets/<name>"})
            return
        name = u.path[len("/sets/"):]
        if not NAME_RE.match(name):
            self._send(400, {"error": f"bad set name {name!r} (^[a-z0-9][a-z0-9._-]{{0,63}}$)"})
            return
        spec = self._body()
        if spec is None:
            self._send(400, {"error": "bad json"})
            return
        err = valid_spec(spec)
        if err:
            self._send(400, {"error": err})
            return
        save_volume(entry=(name, spec))
        log(f"definition {name}: registered {len(spec['files'])} file(s)")
        self._send(201, {"status": f"registered: {name}"})

    def do_DELETE(self):
        u = urlparse(self.path)
        if u.path == "/models":
            name = (parse_qs(u.query).get("set") or [""])[0]
            msg, code = delete_models(name)
            self._send(code, {"status": msg})
        elif u.path.startswith("/sets/"):
            name = u.path[len("/sets/"):]
            if name not in sets():
                self._send(400, {"error": "unknown set"})
                return
            save_volume(drop=name)
            log(f"definition {name}: removed")
            self._send(200, {"status": f"definition removed: {name} "
                                      "(files kept; use DELETE /models?set= to free space)"})
        else:
            self._send(404, {"error": "use DELETE /models?set=name or DELETE /sets/<name>"})

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
            if name not in sets():
                log(f"unknown model set: {name} (known: {sorted(sets())})")
                rc = 1
                continue
            if not fetch_set(name):
                rc = 1
        sys.exit(rc)
    elif cmd == "serve":
        log(f"provisioner on :{PORT}, models={MODELS_DIR}, "
            f"registry={REGISTRY}, sets={sorted(sets())}")
        ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
    else:
        print(f"usage: provision.py [list|fetch a,b|serve]", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
