#!/usr/bin/env python3
"""Ollama context optimize: proxy OpenAI-compatible đứng trước Ollama, tự chọn bản model theo độ dài ngữ cảnh.

Các model có hậu tố `NNNk` (cỡ ngữ cảnh) được gộp thành một họ dưới tên gốc: saluki100k, saluki130k,
saluki150k và saluki (không hậu tố, num_ctx đọc trong Modelfile) -> họ `saluki`. Agent (opencode, omp,
...) gọi tên gốc `saluki`; với mỗi request proxy ước lượng số token và chọn bản nhỏ nhất còn đủ chỗ:
bản nhỏ giữ nhiều lớp trên GPU hơn nên nhanh hơn, chỉ khi ngữ cảnh thật sự lớn mới lên bản lớn.

- Nếu ước lượng thiếu, Ollama trả 400 "request (N tokens) exceeds the available context size":
  proxy đọc N (số token thật), gửi lại sang bản đủ lớn và hiệu chỉnh tỉ lệ ký tự/token theo N.
- Mỗi lần đổi bản Ollama phải tải lại model và đọc lại toàn bộ prompt, nên khi ngữ cảnh giảm
  (agent nén hội thoại) proxy chỉ hạ cấp khi đã thấp hẳn (DOWNGRADE_RATIO), tránh tải qua tải lại.
- Model không thuộc họ nào (và tên bản cụ thể như `saluki130k`) được chuyển thẳng tới Ollama, không đổi gì.
- /v1/models liệt kê mỗi họ một tên gốc, cộng tất cả model khác.

Chỉ dùng thư viện chuẩn. Cấu hình qua biến môi trường (xem bên dưới).
"""
import hashlib
import http.client
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = os.environ.get("SALUKI_AUTO_LISTEN", "127.0.0.1:11435")
UPSTREAM = os.environ.get("SALUKI_AUTO_UPSTREAM", "http://127.0.0.1:11434")
# Chỉ dùng tối đa phần này của num_ctx cho prompt + output (chừa sai số ước lượng)
FILL_RATIO = float(os.environ.get("SALUKI_AUTO_FILL_RATIO", 0.9))
# Chỉ hạ xuống bản nhỏ hơn khi request chiếm dưới tỉ lệ này của bản đó
DOWNGRADE_RATIO = float(os.environ.get("SALUKI_AUTO_DOWNGRADE_RATIO", 0.6))
# Chừa cho output khi request không gửi max_tokens
DEFAULT_OUTPUT_RESERVE = int(os.environ.get("SALUKI_AUTO_OUTPUT_RESERVE", 16384))
# Ký tự JSON trên mỗi token lúc khởi đầu; tự hiệu chỉnh theo usage thật Ollama trả về
INITIAL_CHARS_PER_TOKEN = float(os.environ.get("SALUKI_AUTO_CHARS_PER_TOKEN", 3.0))
# Danh sách model Ollama được đọc lại sau ngần này giây (thêm/xoá bản không cần khởi động lại proxy)
MODELS_CACHE_SECONDS = 60
# Token ước lượng cho mỗi ảnh (dữ liệu base64 của ảnh không được đếm như văn bản)
IMAGE_TOKENS = int(os.environ.get("SALUKI_AUTO_IMAGE_TOKENS", 2048))
# num_ctx mặc định của Ollama khi Modelfile không khai báo
OLLAMA_DEFAULT_CTX = int(os.environ.get("SALUKI_AUTO_DEFAULT_CTX", 4096))
DEBUG = os.environ.get("SALUKI_AUTO_DEBUG") == "1"

# Chat template của saluki chỉ nhận reasoning_effort xhigh (mặc định)/medium/low, nhưng Ollama đổi
# "xhigh" thành "max" trước khi đưa vào template; agent (vd. omp) lại hay gửi "high".
# None = bỏ trường đi để template dùng mặc định xhigh.
EFFORT_MAP = {"high": None, "xhigh": None, "max": None, "minimal": "low", "none": "low"}

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
              "trailers", "transfer-encoding", "upgrade", "content-length", "host"}

_lock = threading.Lock()
_chars_per_token = INITIAL_CHARS_PER_TOKEN
_session_tier: dict[str, int] = {}  # "họ:khoá phiên" -> chỉ số bản đang dùng
_show_cache: dict[str, tuple[int, list[str]] | None] = {}
_models_cache: tuple[float, list[str]] = (0.0, [])
_upstream = urllib.parse.urlsplit(UPSTREAM)


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def _api(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(UPSTREAM + path, data, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def ollama_models():
    global _models_cache
    with _lock:
        fetched_at, names = _models_cache
    if time.time() - fetched_at > MODELS_CACHE_SECONDS:
        names = [m["name"] for m in _api("/api/tags").get("models", [])]
        with _lock:
            _models_cache = (time.time(), names)
            _show_cache.clear()  # model có thể đã được tạo lại với num_ctx khác
    return names


def stem(name):
    return name[:-len(":latest")] if name.endswith(":latest") else name


def show(name):
    """(num_ctx trong Modelfile hoặc 0, capabilities) của một model; None nếu Ollama không đọc được model."""
    if name not in _show_cache:
        try:
            info = _api("/api/show", {"model": name})
        except urllib.error.HTTPError:
            _show_cache[name] = None  # model hỏng (vd. import nhầm file mmproj): bỏ qua
            return None
        params = info.get("parameters", "")
        ctx = next((line.split()[1] for line in params.splitlines() if line.split()[:1] == ["num_ctx"]), None)
        _show_cache[name] = (int(ctx) if ctx else 0, info.get("capabilities") or [])
    return _show_cache[name]


def modelfile_num_ctx(name):
    return (show(name) or (0, []))[0]


def model_entry(model_id, name, ctx):
    """Mục /v1/models kèm metadata mà agent (vd. omp discovery) đọc: context_length, modalities."""
    caps = (show(name) or (0, []))[1]
    entry = {"id": model_id, "object": "model", "created": 0, "owned_by": "ollama-context-optimize",
             "context_length": ctx, "input_modalities": ["text", "image"] if "vision" in caps else ["text"]}
    if "embedding" in caps and "completion" not in caps:
        entry["output_modalities"] = ["embedding"]
    return entry


SUFFIX_RE = re.compile(r"(.+?)[-_]?(\d+)k", re.IGNORECASE)


def families():
    """{tên gốc: [(tên model, num_ctx), ...] nhỏ -> lớn} cho các họ có bản `NNNk`.

    `<gốc>NNNk` / `<gốc>-NNNk` / `<gốc>_NNNk` -> NNN*1000; bản `<gốc>` không hậu tố -> num_ctx trong Modelfile.
    """
    names = ollama_models()
    fams = {}
    for name in names:
        if m := SUFFIX_RE.fullmatch(stem(name)):
            fams.setdefault(m.group(1), []).append((name, int(m.group(2)) * 1000))
    for name in names:
        base = next((b for b in fams if b.lower() == stem(name).lower()), None)
        if base and (ctx := modelfile_num_ctx(name)):
            fams[base].append((name, ctx))
    return {b: sorted(t, key=lambda x: x[1]) for b, t in fams.items()}


def family_of(model):
    """Tên gốc nếu `model` (vd. `saluki`, `saluki:latest`) là một họ, ngược lại None."""
    s = stem(model).lower()
    return next((b for b in families() if b.lower() == s), None)


def session_key(base, body):
    """Một hội thoại agent giữ nguyên system prompt + tin nhắn user đầu tiên."""
    msgs = body.get("messages") or []
    head = [m for m in msgs if m.get("role") == "system"][:1] + [m for m in msgs if m.get("role") == "user"][:1]
    return base + ":" + hashlib.sha1(json.dumps(head, sort_keys=True).encode()).hexdigest()[:12]


def _strip_images(node):
    """Bỏ dữ liệu ảnh (base64) khỏi messages; trả về (bản không ảnh, số ảnh)."""
    if isinstance(node, list):
        parts = [_strip_images(x) for x in node]
        return [p for p, _ in parts], sum(n for _, n in parts)
    if isinstance(node, dict):
        if node.get("type") in ("image_url", "input_image", "image"):
            return {"type": "image"}, 1
        out, count = {}, 0
        for k, v in node.items():
            if k == "images" and isinstance(v, list):  # kiểu Ollama native
                count += len(v)
                continue
            out[k], n = _strip_images(v)
            count += n
        return out, count
    return node, 0


def estimate_tokens(body):
    messages, images = _strip_images(body.get("messages") or [])
    chars = len(json.dumps(messages, ensure_ascii=False))
    chars += len(json.dumps(body.get("tools") or [], ensure_ascii=False))
    with _lock:
        cpt = _chars_per_token
    prompt = int(chars / cpt) + images * IMAGE_TOKENS
    output = body.get("max_tokens") or body.get("max_completion_tokens") or DEFAULT_OUTPUT_RESERVE
    # chars = 0: không hiệu chỉnh tỉ lệ ký tự/token theo request có ảnh (token ảnh thật không đo được)
    return prompt, 0 if images else chars, int(output)


def pick_tier(tiers, key, need):
    fits = [i for i, (_, ctx) in enumerate(tiers) if need <= ctx * FILL_RATIO]
    want = fits[0] if fits else len(tiers) - 1
    with _lock:
        cur = _session_tier.get(key)
        if cur is not None and cur < len(tiers) and want < cur and need > tiers[want][1] * DOWNGRADE_RATIO:
            want = cur  # chưa đủ nhỏ để hạ cấp: giữ bản hiện tại, khỏi tải lại model
        _session_tier[key] = want
        if len(_session_tier) > 1000:
            _session_tier.pop(next(iter(_session_tier)))
    return want, not fits


def learn_ratio(chars, prompt_tokens, exact=False):
    """Hiệu chỉnh ký tự/token theo prompt_tokens thật (trung bình trượt)."""
    global _chars_per_token
    if prompt_tokens < 500 or chars <= 0:
        return
    observed = chars / prompt_tokens
    with _lock:
        if exact:  # vừa ước lượng thiếu: lấy luôn tỉ lệ thật, không làm mượt
            _chars_per_token = min(_chars_per_token, observed)
            return
        # thiên về giá trị nhỏ hơn (ước lượng dư token an toàn hơn thiếu)
        _chars_per_token = min(0.8 * _chars_per_token + 0.2 * observed, observed * 1.05)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # body kết thúc bằng đóng kết nối: stream SSE chuyển thẳng được

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            return self._models()
        self._forward(None)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.startswith("/v1/chat/completions"):
            try:
                body = json.loads(raw)
            except ValueError:
                body = None
            model = body.get("model") if isinstance(body, dict) else None
            if isinstance(model, str):
                try:
                    base = family_of(model)
                except OSError as e:
                    return self.send_error(502, f"upstream error: {e}")
                if base:
                    return self._route_family(base, body)
        self._forward(raw)

    def _route_family(self, base, body):
        tiers = families()[base]
        prompt, chars, output = estimate_tokens(body)
        key = session_key(base, body)
        idx, overflow = pick_tier(tiers, key, prompt + output)
        if DEBUG:
            log("request fields: " + json.dumps({k: v for k, v in body.items() if k not in ("messages", "tools")}))
        effort = body.get("reasoning_effort")
        if effort in EFFORT_MAP:
            if EFFORT_MAP[effort] is None:
                del body["reasoning_effort"]
            else:
                body["reasoning_effort"] = EFFORT_MAP[effort]
        log(f"{base}: ~{prompt} prompt + {output} output tokens -> {tiers[idx][0]}"
            + (" (vượt bản lớn nhất)" if overflow else ""))
        # Nếu Ollama báo vượt ngữ cảnh thì gửi lại sang bản đủ lớn
        while True:
            body["model"] = tiers[idx][0]
            try:
                conn, resp = self._open(json.dumps(body).encode())
            except OSError as e:
                return self.send_error(502, f"upstream error: {e}")
            if resp.status != 400:
                return self._relay(conn, resp, chars)
            err = resp.read()
            conn.close()
            m = re.search(rb"request \((\d+) tokens\) exceeds the available context size", err)
            bigger = None
            if m:
                tokens = int(m.group(1))
                learn_ratio(chars, tokens, exact=True)
                bigger = next((i for i, (_, ctx) in enumerate(tiers) if i > idx and tokens + output <= ctx), None)
            if bigger is None:
                if m:
                    log(f"{base}: {tokens} prompt tokens vượt cả bản lớn nhất, trả lỗi cho agent (agent sẽ nén hội thoại)")
                return self._send(400, err)
            log(f"{base}: thực tế {tokens} prompt tokens (ước lượng thiếu) -> gửi lại tới {tiers[bigger][0]}")
            idx = bigger
            with _lock:
                _session_tier[key] = idx

    def _models(self):
        """Mỗi họ một tên gốc (context = FILL_RATIO bản lớn nhất) + tất cả model khác."""
        try:
            fams = families()
            grouped = {name for tiers in fams.values() for name, _ in tiers}
            entries = [model_entry(b, tiers[-1][0], int(tiers[-1][1] * FILL_RATIO)) for b, tiers in sorted(fams.items())]
            for name in ollama_models():
                if name not in grouped and show(name) is not None:
                    m = SUFFIX_RE.fullmatch(stem(name))
                    ctx = int(m.group(2)) * 1000 if m else modelfile_num_ctx(name) or OLLAMA_DEFAULT_CTX
                    entries.append(model_entry(name, name, ctx))
        except OSError as e:
            return self.send_error(502, f"upstream error: {e}")
        self._send(200, json.dumps({"object": "list", "data": entries}).encode())

    def _send(self, status, payload):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _open(self, raw):
        conn = http.client.HTTPConnection(_upstream.hostname, _upstream.port or 80, timeout=7200)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        if raw is not None:
            headers["Content-Length"] = str(len(raw))
        conn.request(self.command, self.path, body=raw, headers=headers)
        return conn, conn.getresponse()

    def _forward(self, raw):
        try:
            conn, resp = self._open(raw)
        except OSError as e:
            return self.send_error(502, f"upstream error: {e}")
        self._relay(conn, resp)

    def _relay(self, conn, resp, chars=0):
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP_BY_HOP:
                self.send_header(k, v)
        self.end_headers()
        tail = b""
        try:
            while chunk := resp.read1(65536):
                self.wfile.write(chunk)
                self.wfile.flush()
                if chars:
                    tail = (tail + chunk)[-8192:]  # usage nằm ở cuối response / chunk SSE cuối
        except (BrokenPipeError, ConnectionResetError):
            pass  # client ngắt: đóng kết nối upstream để Ollama dừng sinh token
        finally:
            conn.close()
        if chars and (found := re.findall(rb'"prompt_tokens"\s*:\s*(\d+)', tail)):
            learn_ratio(chars, int(found[-1]))


def main():
    host, _, port = LISTEN.rpartition(":")
    try:
        found = "; ".join(f"{b} = " + " < ".join(f"{stem(n)}({c})" for n, c in tiers)
                          for b, tiers in families().items())
    except OSError as e:
        found = f"(chưa đọc được Ollama: {e})"
    log(f"ollama-context-optimize {LISTEN} -> {UPSTREAM}; {found}")
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
