#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把本地 ipa（或任意文件）上传到「全能签 · 无线传输」网页服务，并归到「资源 App」栏。

为什么单独写一个脚本：
  全能签的网页上传走的是「分块 + 续传」私有协议，不是普通 multipart 表单：
    1) POST /api/upload/init      {fileName, totalSize}  -> {uploadId, chunkSize, offset}
    2) POST /api/upload/chunk?uploadId=&start=&end=&total=   （multipart: uploadId/start/end/total/chunk）
    3) POST /api/upload/complete  {uploadId}
  直接 PUT 一个整文件上去会被拒。这里按它的协议走，慢网也能断点续传。

  另外：init **不接受目标目录**，传上去的文件一定先落在「下载」(UserDownloads) 栏。
  想进「资源 App」(Resources/IPA) 只能再走一次
    4) POST /api/import-from-download {path}  -> {taskId}（这一步会移动文件并解析 Info.plist）
  脚本默认自动做这一步，所以上传完直接在「资源 App」栏就能点开签名。

用法：
    python upload-to-qnq.py <文件路径> [--server http://ip:8080] [--password 访问密码]
                            [--name 自定义文件名] [--no-import] [--json]

    --server 不填时自动探测：先试上次成功的地址，再试「手机热点 172.20.10.1」、
    历史局域网地址、以及本机所在网段的网关。全能签显示的地址会随手机换网络而变
    （连 Wi-Fi 是一个地址，开热点是 172.20.10.1），所以别把它写死。

退出码：0 成功；1 失败（stderr 有原因）。
"""
from __future__ import annotations

import argparse
import http.cookiejar
import json
import mimetypes
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
import uuid

DEFAULT_SERVER = "http://192.168.10.13:8080"
DEFAULT_DIR = "Resources/IPA"  # 全能签网页里的「资源 APP」栏

# 上次探测成功的地址。写在脚本旁边，跟着技能走。
LAST_SERVER_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".qnq_last_server")

# 手机换网络后地址会变，这里列的是「大概率」的几个：
#   100.107.103.66 —— 手机在 tailnet 里的固定地址（iphone-14-pro-max），
#                     换 Wi-Fi / 换热点都不变，是最稳的一条；前提是
#                     手机上 Tailscale 开着、全能签的无线传输也开着
#   172.20.10.1   —— iOS 个人热点的固定网关，电脑连手机热点时就是它
#   192.168.10.13 —— 之前常用的局域网地址
CANDIDATE_SERVERS = [
    "http://100.107.103.66:8080",
    "http://172.20.10.1:8080",
    DEFAULT_SERVER,
    "http://10.64.11.195:8080",
    "http://127.0.0.1:8080",
]


def build_opener() -> urllib.request.OpenerDirector:
    jar = http.cookiejar.CookieJar()
    # 关掉环境里的 HTTP_PROXY：本机常有全局代理，会把内网请求也带走
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
    )
    return opener


# MARK: - 服务地址自动探测

def _gateway_candidates() -> list[str]:
    """本机走默认路由时的出口网段，取 .1 当网关试一下。

    手机热点场景下正好命中 172.20.10.1；接在别的路由器后面时
    网关是路由器而不是手机，试一下也不亏（失败很快）。
    """
    try:
        probe_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe_sock.settimeout(0.5)
        # UDP connect 不会真的发包，只用来问内核「走哪个源地址」
        probe_sock.connect(("8.8.8.8", 53))
        local_ip = probe_sock.getsockname()[0]
        probe_sock.close()
    except Exception:
        return []

    parts = local_ip.split(".")
    if len(parts) != 4:
        return []
    subnet = ".".join(parts[:3])
    return [f"http://{subnet}.1:8080"]


def _remembered_server() -> str | None:
    try:
        with open(LAST_SERVER_FILE, "r", encoding="utf-8") as fh:
            value = fh.read().strip()
        return value or None
    except OSError:
        return None


def remember_server(server: str) -> None:
    try:
        with open(LAST_SERVER_FILE, "w", encoding="utf-8") as fh:
            fh.write(server)
    except OSError:
        pass


def server_candidates() -> list[str]:
    ordered: list[str] = []
    for item in [_remembered_server(), os.environ.get("QNQ_SERVER"), *CANDIDATE_SERVERS, *_gateway_candidates()]:
        if not item:
            continue
        normalized = item.rstrip("/")
        if normalized and normalized not in ordered:
            ordered.append(normalized)
    return ordered


def _local_ipv4() -> str | None:
    """借 UDP connect 问内核「出口网卡是哪个地址」，不发包。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.5)
    try:
        sock.connect(("8.8.8.8", 53))
        return sock.getsockname()[0]
    except Exception:
        return None
    finally:
        sock.close()


def scan_lan(port: int = 8080, timeout: float = 0.9) -> list[str]:
    """扫本机所在 /24 的 8080 端口。

    手机换 Wi-Fi / 重连后 DHCP 会分到新地址（历史上 192.168.10.13 → 192.168.10.12），
    写死候选地址必然越来越不准。这里兜底扫一遍，比让用户去手机上看 IP 快。
    """
    ip = _local_ipv4()
    if not ip or ip.count(".") != 3:
        return []
    prefix = ip.rsplit(".", 1)[0]

    def hit(host: str) -> str | None:
        sock = socket.socket()
        sock.settimeout(timeout)
        try:
            sock.connect((host, port))
            return host
        except Exception:
            return None
        finally:
            sock.close()

    hosts = [f"{prefix}.{i}" for i in range(1, 255)]
    with ThreadPoolExecutor(max_workers=128) as pool:
        found = [h for h in pool.map(hit, hosts) if h]
    return [f"http://{h}:{port}" for h in found]


def is_alive(server: str, timeout: float = 1.5) -> bool:
    """只问一句 auth/status —— 通了就说明无线传输服务在这个地址上。"""
    try:
        req = urllib.request.Request(
            f"{server}/api/auth/status",
            headers={"Accept": "application/json"},
        )
        with build_opener().open(req, timeout=timeout) as resp:
            return resp.getcode() == 200
    except Exception:
        return False


def resolve_server(explicit: str | None) -> str:
    """显式给了地址就直接用；没给（或给 auto）就先试候选，最后扫局域网。"""
    if explicit and explicit.strip().lower() != "auto":
        server = explicit.strip().rstrip("/")
        remember_server(server)
        return server

    for candidate in server_candidates():
        if is_alive(candidate):
            remember_server(candidate)
            print(f"探测到无线传输服务：{candidate}", file=sys.stderr)
            return candidate

    # 候选地址全不通（手机 DHCP 换了网段是常态）→ 扫一遍本机所在的 /24
    print("候选地址都不通，正在扫描局域网 8080 端口……", file=sys.stderr)
    # 两轮：首轮短超时快，次轮加长——手机刚重连 Wi-Fi 时 ARP 未就绪，0.4s 会漏
    for attempt, tmo in enumerate((0.9, 1.8), start=1):
        hits = scan_lan(timeout=tmo)
        if attempt == 2 and not hits:
            print("第一轮无回应，加长超时重扫……", file=sys.stderr)
        for server in hits:
            if is_alive(server):
                remember_server(server)
                print(f"扫描到无线传输服务：{server}", file=sys.stderr)
                return server

    tried = "\n  ".join(server_candidates())
    raise SystemExit(
        "找不到全能签的「无线传输」服务。试过这些地址：\n  "
        + tried
        + "\n也扫描了本机所在网段的 8080 端口，没有回应。"
        + "\n检查：① 手机上全能签的「无线传输」开关是否打开 ② 电脑和手机是否在同一网络"
        + "\n如果它显示的地址不在另一个网段，用 --server http://<地址> 指定。"
    )


def call_json(opener, url: str, payload: dict | None = None, timeout: int = 30,
              raw_body: bytes | None = None, content_type: str | None = None) -> dict:
    data = raw_body
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")
    try:
        with opener.open(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as exc:
        # 全能签把失败原因放在响应体的 JSON 里（"路径无效" / "偏移不匹配" 等），
        # 不读出来就只剩一个 HTTP 400，排查不了。
        raw = exc.read() or b""
        try:
            parsed = json.loads(raw.decode("utf-8", "replace"))
            parsed.setdefault("ok", False)
            return parsed
        except Exception:
            return {"ok": False, "error": f"HTTP {exc.code} {raw[:200].decode('utf-8', 'replace')}"}
    if not body:
        return {"ok": True}
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except json.JSONDecodeError:
        return {"ok": False, "error": "服务端返回非 JSON: " + body[:200].decode("utf-8", "replace")}


def multipart(fields: list[tuple[str, str]], file_field: str, filename: str, blob: bytes) -> tuple[bytes, str]:
    boundary = "----QNQUpload" + uuid.uuid4().hex
    out = bytearray()
    for key, value in fields:
        out += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n{value}\r\n".encode("utf-8")
    out += (
        f"--{boundary}\r\n"
        f"Content-Disposition: form-data; name=\"{file_field}\"; filename=\"{filename}\"\r\n"
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode("utf-8")
    out += blob
    out += f"\r\n--{boundary}--\r\n".encode("utf-8")
    return bytes(out), f"multipart/form-data; boundary={boundary}"


def login_if_needed(opener, server: str, password: str | None) -> None:
    status = call_json(opener, f"{server}/api/auth/status")
    if status.get("required") is True and status.get("authenticated") is not True:
        if not password:
            raise SystemExit("这台服务器开了访问密码，请加 --password")
        res = call_json(opener, f"{server}/api/auth/login", {"password": password})
        if not res.get("ok"):
            raise SystemExit("登录失败：" + str(res.get("message") or res.get("error") or res))


def list_dir(opener, server: str, rel: str) -> list[dict]:
    url = f"{server}/api/list?path={urllib.parse.quote(rel)}"
    try:
        res = call_json(opener, url)
    except Exception:
        return []
    return res.get("items") or []


def import_to_apps(opener, server: str, download_path: str, timeout: float = 90.0) -> dict:
    """把「下载」栏里的文件导入到「资源 App」栏。

    服务端没有 move/copy 接口，网页上的「导入」就是唯一入口：
    它会移动文件并解包读 Info.plist（所以 ipa 在列表里能显示图标、名称、版本号）。
    返回 {ok, path} 或 {ok: False, error}。
    """
    res = call_json(opener, f"{server}/api/import-from-download", {"path": download_path})
    if not res.get("ok"):
        return {"ok": False, "error": res.get("error") or str(res)}
    task_id = res.get("taskId")
    if not task_id:
        return {"ok": True, "path": ""}

    deadline = time.time() + timeout
    while time.time() < deadline:
        st = call_json(opener, f"{server}/api/import/status?taskId={urllib.parse.quote(str(task_id))}")
        state = (st.get("state") or st.get("status") or "").lower()
        if state in ("done", "completed", "success", "finished") or st.get("done") is True:
            return {"ok": True, "path": st.get("path") or ""}
        if state in ("failed", "error", "cancelled") or st.get("ok") is False:
            return {"ok": False, "error": st.get("error") or state}
        time.sleep(1.0)
    return {"ok": False, "error": "导入超时"}


def upload(path: str, server: str, password: str | None, name: str | None,
           do_import: bool = True) -> dict:
    server = server.rstrip("/")
    filename = name or os.path.basename(path)
    total = os.path.getsize(path)
    opener = build_opener()
    login_if_needed(opener, server, password)

    # init **没有** 目标目录参数，文件一定先落到「下载」栏
    init = call_json(opener, f"{server}/api/upload/init",
                     {"fileName": filename, "totalSize": total, "fresh": True})
    if not init.get("ok") or not init.get("uploadId"):
        raise SystemExit("init 失败：" + str(init.get("error") or init))

    upload_id = init["uploadId"]
    chunk_size = int(init.get("chunkSize") or 2 * 1024 * 1024)
    offset = int(init.get("offset") or 0)

    started = time.time()
    sent_at_last = offset
    last_print = 0.0

    with open(path, "rb") as fh:
        while offset < total:
            fh.seek(offset)
            blob = fh.read(chunk_size)
            if not blob:
                break
            end = offset + len(blob) - 1
            query = urllib.parse.urlencode(
                {"uploadId": upload_id, "start": offset, "end": end, "total": total}
            )
            body, ctype = multipart(
                [("uploadId", upload_id), ("start", str(offset)), ("end", str(end)), ("total", str(total))],
                "chunk", "chunk.part", blob,
            )

            attempt = 0
            res: dict = {}
            progressed = False
            while attempt <= 3:
                try:
                    res = call_json(opener, f"{server}/api/upload/chunk?{query}",
                                    raw_body=body, content_type=ctype, timeout=300)
                except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
                    res = {"ok": False, "error": str(exc)}

                if res.get("ok"):
                    nxt = res.get("receivedBytes")
                    offset = int(nxt) if isinstance(nxt, int) and nxt > offset else end + 1
                    progressed = True
                    break

                attempt += 1
                # 偏移对不上时先问服务端收到哪儿，再从那里续传
                try:
                    st = call_json(opener, f"{server}/api/upload/status?uploadId={urllib.parse.quote(upload_id)}")
                    got = st.get("receivedBytes")
                    if isinstance(got, int) and got > offset:
                        offset = got
                        progressed = True
                        break
                except Exception:
                    pass
                time.sleep(0.4 * attempt)

            if not progressed:
                raise SystemExit(f"分块上传失败（offset={offset}）：{res.get('error')}")

            now = time.time()
            if now - last_print > 0.5 or offset >= total:
                last_print = now
                speed = (offset - sent_at_last) / max(now - started, 1e-6)
                pct = offset * 100.0 / max(total, 1)
                sys.stderr.write(f"\r  {pct:5.1f}%  {offset/1048576:.1f}/{total/1048576:.1f} MB  {speed/1048576:.1f} MB/s")
                sys.stderr.flush()
    sys.stderr.write("\n")

    done = call_json(opener, f"{server}/api/upload/complete", {"uploadId": upload_id})
    if not done.get("ok"):
        raise SystemExit("complete 失败：" + str(done.get("error") or done))

    # complete 返回的 path 只有文件名，导入接口却要求「UserDownloads/xxx」带前缀
    raw = done.get("path") or filename
    download_path = raw if raw.startswith("UserDownloads/") else f"UserDownloads/{raw.lstrip('/')}"
    result = {
        "ok": True,
        "server": server,
        "fileName": filename,
        "bytes": total,
        "seconds": round(time.time() - started, 2),
        "downloadPath": download_path,
        "appPath": "",
    }

    # 上传只到「下载」栏；再导入一次才进「资源 App」
    if do_import:
        imported = import_to_apps(opener, server, download_path)
        if imported.get("ok"):
            result["appPath"] = imported.get("path") or f"{DEFAULT_DIR}/{filename}"
        else:
            result["ok"] = False
            result["error"] = "文件已上传到「下载」栏，但导入「资源 App」失败：" + str(imported.get("error"))
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--server", default=None,
                    help="http://ip:8080；不填则自动探测（也接受 auto）")
    ap.add_argument("--password", default=os.environ.get("QNQ_PASSWORD"))
    ap.add_argument("--name", default=None, help="上传后的文件名（默认取本地文件名）")
    ap.add_argument("--no-import", dest="do_import", action="store_false",
                    help="只上传到「下载」栏，不导入「资源 App」")
    ap.add_argument("--json", action="store_true", help="只输出 JSON（给自动化用）")
    args = ap.parse_args()

    if not os.path.isfile(args.file):
        print(f"文件不存在：{args.file}", file=sys.stderr)
        return 1

    try:
        server = resolve_server(args.server)
        result = upload(args.file, server, args.password, args.name, args.do_import)
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(f"上传完成：{result['fileName']}  {result['bytes']/1048576:.2f} MB  "
              f"耗时 {result['seconds']}s")
        if result.get("appPath"):
            print(f"已进「资源 App」：{result['appPath']}")
        print(f"打开 {result['server']}/ 就能看到并签名")
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
