#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
snore_ctl.py — 电脑端控制台：切页 / 清零 / 看板

为什么要有这个：
    板上那两个按键（key[0] 切页、key[1] 清零）在床头的板子上，
    演示时要伸手去按；调参时人在电脑前，更不想来回跑。
    固件从 v4 起支持串口单字符命令，这个脚本就是它的上位机。

为什么界面开在浏览器里而不是 tkinter：
    这台机器上的 Python 是便携版，没带 tkinter（import 直接报
    ModuleNotFoundError）。为了不逼用户去装 Python 发行版，
    这里用标准库 http.server 起一个只监听 127.0.0.1 的小服务，
    界面用 HTML 写，浏览器打开即可 —— 零额外依赖，样子也比 tk 好看。

两种用法
--------
1) 界面（双击 切换界面.bat，或直接运行不带参数）：

       python snore_ctl.py

   脚本会起本地服务并自动打开浏览器。页面上点按钮就能切页 / 清零，
   同时实时显示包络波形和四个判据灯。
   点完按钮会显示"已确认"—— 它不是猜的，
   而是读板子回传的 G 字段（命令计数）确认过的。

2) 命令行（写批处理 / 远程操作时用）：

       python snore_ctl.py COM7 --page report
       python snore_ctl.py COM7 --page toggle
       python snore_ctl.py COM7 --clr
       python snore_ctl.py COM7 --probe

串口协议（固件侧实现见 rtl/cmd_parse.v）
----------------------------------------
    下行：单字符，大小写都收
        P / p        翻转页面
        T / t / 0    切到实时页
        R / r / 1    切到报告页
        C / c        清零统计（等同按键 key[1]）
        ? / h / H    探活，不改任何状态，只让命令计数 +1
    上行：每 32ms 一行，38 字节
        F0012 P01F4 A0033 E02A1 S9 C0E R2 G0
        G = {页号, 命令计数[2:0]}，bit3 是当前页，bit2..0 是收到的命令数

依赖：pyserial（其余全是标准库）
"""

import argparse
import json
import re
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    print("[!] 缺少 pyserial，请先执行: pip install pyserial")
    sys.exit(1)

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:                                       # noqa: BLE001
    pass


FRAME_RE = re.compile(
    r"F([0-9A-Fa-f]{4})\s+P([0-9A-Fa-f]{4})\s+A([0-9A-Fa-f]{4})"
    r"\s+E([0-9A-Fa-f]{4})\s+S([0-9A-Fa-f])\s+C([0-9A-Fa-f]{2})\s+R([0-9A-Fa-f])"
    r"(?:\s+G([0-9A-Fa-f]))?"
)

BIT_NAMES = ["响", "持续", "鼾声", "节律"]

# 命令 -> 说明（页面按钮与命令行共用这一份表）
CMDS = {
    "P": "翻转页面",
    "T": "切到实时页",
    "R": "切到报告页",
    "C": "清零统计",
    "?": "探活",
}

TH_RTL = 525        # 与 snore_judge.v 的门限一致，画图时画参考线
ENV_FULL = 2048     # 包络条满量程（超过 2048 已经算很响，便于看细节）
HISTORY = 600       # 波形窗口保留的帧数（600 × 32ms ≈ 19 秒）


# ---------------------------------------------------------------------------
# 串口帧
# ---------------------------------------------------------------------------
class Frame:
    __slots__ = ("t", "no", "peak", "mean", "env", "st", "cnt", "rhy", "g")

    def __init__(self, t, no, peak, mean, env, st, cnt, rhy, g):
        self.t, self.no, self.peak, self.mean = t, no, peak, mean
        self.env, self.st, self.cnt, self.rhy = env, st, cnt, rhy
        self.g = g

    @property
    def page(self):
        """当前页：0 实时 / 1 报告。老固件没有 G 字段时返回 None。"""
        return None if self.g is None else (self.g >> 3) & 1

    @property
    def cmd_cnt(self):
        """已收到的合法命令数（3 位循环）。老固件没有 G 字段时返回 None。"""
        return None if self.g is None else (self.g & 0x7)

    @property
    def snore(self):
        return bool((self.st >> 2) & 1)


def parse_line(raw):
    m = FRAME_RE.search(raw.decode("ascii", "replace"))
    if not m:
        return None
    g = [int(x, 16) if x else None for x in m.groups()]
    return Frame(time.time(), g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7])


def auto_port():
    """优先挑 CH340 / CP210x 这类 USB 串口"""
    best, best_score = None, -1
    for p in list_ports.comports():
        desc = (p.description or "").lower()
        score = 0
        if "ch340" in desc or "ch341" in desc or "usb-serial" in desc:
            score = 2
        elif "cp210" in desc or "ft232" in desc:
            score = 1
        if score > best_score:
            best, best_score = p.device, score
    return best


# ---------------------------------------------------------------------------
# 串口桥：读线程 + 最新状态 + 命令确认
# ---------------------------------------------------------------------------
class Bridge:
    def __init__(self):
        self.lock = threading.Lock()
        self.ser = None
        self.reader = None
        self.port = None
        self.err = ""
        self.frames = []            # 最近若干帧
        self.det = 0                # 判决累计
        self.last_st = 0
        self.pending = None         # {"ch","name","t0","base"}
        self.ack = ""               # 上一条命令的确认文字
        self.ack_ok = None          # True / False / None

    # ---- 连接 ----
    def open(self, port):
        self.close()
        try:
            ser = serial.Serial(port, 115200, timeout=0.1)
            ser.reset_input_buffer()
        except Exception as e:                          # noqa: BLE001
            self.err = "打不开 %s：%s" % (port, e)
            return False
        self.ser, self.port, self.err = ser, port, ""
        self.frames, self.det, self.last_st = [], 0, 0
        self.pending, self.ack, self.ack_ok = None, "", None
        self.reader = _Reader(self, ser)
        self.reader.start()
        return True

    def close(self):
        if self.reader:
            self.reader.stop_flag = True
            self.reader = None
        if self.ser:
            try:
                self.ser.close()
            except Exception:                           # noqa: BLE001
                pass
        self.ser, self.port = None, None

    @property
    def connected(self):
        return self.ser is not None

    # ---- 收帧 ----
    def push(self, fr):
        with self.lock:
            self.frames.append(fr)
            if len(self.frames) > HISTORY * 2:
                self.frames = self.frames[-HISTORY:]
            if fr.snore and not (self.last_st >> 2) & 1:
                self.det += 1
            self.last_st = fr.st

            # 命令确认：命令计数变了就说明板子收到了
            p = self.pending
            if p is not None and fr.cmd_cnt is not None:
                if fr.cmd_cnt != p["base"]:
                    self.pending = None
                    self.ack = "已确认：%s（命令计数 → %d）" % (p["name"], fr.cmd_cnt)
                    self.ack_ok = True
                elif time.time() - p["t0"] > 2.0:
                    self.pending = None
                    self.ack = "没收到确认，检查跳线是否在 PL 侧、固件是否为 v4 以上"
                    self.ack_ok = False

    # ---- 发命令 ----
    def send(self, ch):
        if not self.connected:
            return False, "还没连接串口"
        with self.lock:
            if self.pending is not None:
                return False, "上一条命令还在等确认"
            base = None
            for fr in reversed(self.frames):
                if fr.cmd_cnt is not None:
                    base = fr.cmd_cnt
                    break
            if base is None:
                return False, "还没收到带 G 字段的遥测帧（固件太旧或板子没跑）"
            self.pending = {"ch": ch, "name": CMDS.get(ch, "自定义命令"),
                            "t0": time.time(), "base": base}
            self.ack, self.ack_ok = "", None
        try:
            self.ser.write(ch.encode("ascii"))
            self.ser.flush()
        except Exception as e:                          # noqa: BLE001
            with self.lock:
                self.pending = None
                self.ack, self.ack_ok = "发送失败：%s" % e, False
            return False, str(e)
        return True, ""

    # ---- 状态快照（给网页轮询）----
    def state(self):
        with self.lock:
            tail = self.frames[-HISTORY:]
            fr = tail[-1] if tail else None
            p = self.pending
            return {
                "connected": self.connected,
                "port": self.port or "",
                "err": self.err,
                "has_data": fr is not None,
                "page": None if (fr is None or fr.page is None) else fr.page,
                "cmd_cnt": None if (fr is None or fr.cmd_cnt is None) else fr.cmd_cnt,
                "env": 0 if fr is None else fr.env,
                "st": 0 if fr is None else fr.st,
                "det": self.det,
                "pending": None if p is None else p["ch"],
                "ack": self.ack,
                "ack_ok": self.ack_ok,
                "env_hist": [f.env for f in tail],
                "snore_hist": [1 if f.snore else 0 for f in tail],
                "th": TH_RTL,
                "env_full": ENV_FULL,
            }


class _Reader(threading.Thread):
    def __init__(self, bridge, ser):
        super().__init__(daemon=True)
        self.bridge = bridge
        self.ser = ser
        self.stop_flag = False

    def run(self):
        buf = b""
        while not self.stop_flag:
            try:
                chunk = self.ser.read(512)
            except Exception:                           # noqa: BLE001
                break
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                fr = parse_line(line)
                if fr is not None:
                    self.bridge.push(fr)
            if len(buf) > 4096:
                buf = b""


# ---------------------------------------------------------------------------
# 网页界面（内嵌，省得再管一个文件路径）
# ---------------------------------------------------------------------------
PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>鼾声检测 · 控制台</title>
<style>
  :root{--bg:#0d1117;--panel:#161b22;--line:#21262d;--fg:#d8e4ec;
        --dim:#7d8f9c;--blue:#1f6feb;--purple:#8957e5;--green:#238636;
        --amber:#9e6a03;--ok:#2ea043;--warn:#d29922;--err:#f85149}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);
       font:14px/1.5 "Microsoft YaHei UI","Segoe UI",system-ui,sans-serif}
  .wrap{max-width:960px;margin:0 auto;padding:18px}
  h1{font-size:17px;margin:0 0 14px;font-weight:600;letter-spacing:.5px}
  h1 span{color:var(--dim);font-weight:400;font-size:12px;margin-left:10px}
  .bar{display:flex;align-items:center;gap:8px;background:var(--panel);
       border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin-bottom:14px}
  select,button{font:inherit;color:var(--fg);background:#0d1117;
       border:1px solid var(--line);border-radius:6px;padding:6px 10px;outline:none}
  button{cursor:pointer;background:var(--blue);border-color:transparent;font-weight:600}
  button.ghost{background:#21262d;font-weight:400}
  .status{margin-left:auto;font-size:12px;color:var(--dim)}
  .status b{color:var(--ok)}
  .status.bad b{color:var(--err)}
  .grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:14px}
  .btn{background:var(--c);border-radius:10px;padding:20px 18px;cursor:pointer;
       user-select:none;transition:transform .06s,filter .12s}
  .btn:hover{filter:brightness(1.12)}
  .btn:active{transform:scale(.98)}
  .btn .t{font-size:20px;font-weight:700;letter-spacing:1px}
  .btn .s{font:12px/1.4 Consolas,monospace;opacity:.75;margin-top:4px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:8px;
        padding:14px 16px;margin-bottom:14px}
  .row{display:flex;align-items:center;gap:14px;margin-bottom:10px}
  .row:last-child{margin-bottom:0}
  .label{color:var(--dim);font-size:12px;width:64px;flex:none}
  .page{font-size:22px;font-weight:700}
  .page.rt{color:#79c0ff}.page.rpt{color:#c297ff}
  .envbar{flex:1;height:16px;background:#0d1117;border-radius:4px;position:relative;
          overflow:hidden;border:1px solid var(--line)}
  .envbar i{position:absolute;left:0;top:0;bottom:0;background:var(--ok);width:0;
            transition:width .08s linear}
  .envbar i.hot{background:var(--err)}
  .envbar u{position:absolute;top:-2px;bottom:-2px;width:0;
            border-left:1px dashed var(--warn)}
  .val{font:13px/1 Consolas,monospace;color:var(--fg);width:64px;text-align:right}
  .lamps{display:flex;gap:8px}
  .lamp{padding:7px 14px;border-radius:6px;background:#21262d;color:var(--dim);
        font-size:13px;transition:background .12s,color .12s}
  .lamp.on{background:var(--ok);color:#fff;font-weight:600}
  .ack{font-size:12px;min-height:18px}
  .ack.ok{color:var(--ok)}.ack.bad{color:var(--err)}.ack.wait{color:var(--warn)}
  canvas{width:100%;height:190px;display:block;background:#0d1117;
         border:1px solid var(--line);border-radius:6px}
  .tips{color:var(--dim);font-size:12px}
  .tips code{background:#21262d;padding:1px 6px;border-radius:4px;
             font-family:Consolas,monospace}
</style></head><body><div class="wrap">

<h1>鼾声检测 · 控制台<span>ATK-4384 / ZYNQ7010</span></h1>

<div class="bar">
  <select id="port"></select>
  <button id="conn">连接</button>
  <button class="ghost" id="refresh">刷新串口</button>
  <div class="status" id="status">未连接</div>
</div>

<div class="grid">
  <div class="btn" style="--c:var(--blue)"   onclick="cmd('T')">
    <div class="t">实时页</div><div class="s">T / t / 0</div></div>
  <div class="btn" style="--c:var(--purple)" onclick="cmd('R')">
    <div class="t">报告页</div><div class="s">R / r / 1</div></div>
  <div class="btn" style="--c:var(--green)"  onclick="cmd('P')">
    <div class="t">切换页面</div><div class="s">P / p</div></div>
  <div class="btn" style="--c:var(--amber)"  onclick="cmd('C')">
    <div class="t">清零统计</div><div class="s">C / c</div></div>
</div>

<div class="card">
  <div class="row">
    <div class="label">当前页</div>
    <div class="page" id="page">--</div>
    <div class="ack" id="ack" style="margin-left:auto"></div>
  </div>
  <div class="row">
    <div class="label">包络 E</div>
    <div class="envbar"><i id="envfill"></i><u id="envth"></u></div>
    <div class="val" id="envval">0</div>
  </div>
  <div class="row">
    <div class="label">判据</div>
    <div class="lamps">
      <div class="lamp" id="l0">响</div><div class="lamp" id="l1">持续</div>
      <div class="lamp" id="l2">鼾声</div><div class="lamp" id="l3">节律</div>
    </div>
    <div class="val" id="det" style="width:auto;margin-left:auto">判决 0 次</div>
  </div>
</div>

<div class="card" style="padding:14px 14px 10px">
  <div class="tips" style="margin-bottom:8px">最近 19 秒包络（红框 = 判为鼾声的帧，虚线 = 门限）</div>
  <canvas id="cv" width="1800" height="380"></canvas>
</div>

<div class="card tips">
  板子上的 <code>key[0]</code>、<code>key[1]</code> 和这里的按钮效果完全一样，两边随便用。
  每点一次按钮，板子会在遥测帧的 <code>G</code> 字段回传命令计数，
  页面看到它变了才显示"已确认"—— 不是假装成功。
</div>

<script>
const $ = id => document.getElementById(id);

async function j(u){ try{ const r = await fetch(u); return await r.json(); }catch(e){ return null; } }

async function loadPorts(){
  const d = await j('/ports');
  if(!d) return;
  const sel = $('port');
  sel.innerHTML = '';
  (d.ports.length ? d.ports : ['(没有可用串口)']).forEach(p=>{
    const o = document.createElement('option');
    o.value = p; o.textContent = p;
    sel.appendChild(o);
  });
  if(d.auto) sel.value = d.auto;
}

async function toggleConn(){
  const st = await j('/state');
  if(st && st.connected){
    await j('/disconnect');
    $('conn').textContent = '连接';
  } else {
    const p = $('port').value;
    const r = await j('/connect?port=' + encodeURIComponent(p));
    if(r && r.ok) $('conn').textContent = '断开';
    else if(r) alert(r.msg || '连接失败');
  }
  poll();
}

async function cmd(c){
  const r = await j('/cmd?c=' + c);
  if(r && !r.ok) $('ack').textContent = r.msg || '发送失败';
  poll();
}

function drawHist(h, sn, th, full){
  const cv = $('cv'), g = cv.getContext('2d');
  const W = cv.width, H = cv.height;
  g.fillStyle = '#0d1117'; g.fillRect(0,0,W,H);
  if(!h || h.length < 2){
    g.fillStyle = '#30363d'; g.font = '26px Consolas';
    g.fillText('等待数据 ...', 40, H/2);
    return;
  }
  const n = h.length;
  const top = Math.max(full, ...h);
  const sx = W / (n - 1);
  const y = v => H - 24 - (Math.min(v, top) / top) * (H - 56);

  // 鼾声帧红框
  g.strokeStyle = 'rgba(248,81,73,0.45)'; g.lineWidth = 2;
  let i = 0;
  while(i < n){
    if(sn[i]){
      let k = i; while(k < n && sn[k]) k++;
      const x0 = i * sx, x1 = Math.max((k-1) * sx, x0 + 2);
      g.strokeRect(x0, 2, x1 - x0, H - 4);
      i = k;
    } else i++;
  }

  // 门限
  const yth = y(th);
  g.strokeStyle = '#e3b341'; g.setLineDash([10,8]); g.lineWidth = 2;
  g.beginPath(); g.moveTo(0, yth); g.lineTo(W, yth); g.stroke();
  g.setLineDash([]);

  // 包络曲线
  g.strokeStyle = '#4ac26b'; g.lineWidth = 3; g.beginPath();
  for(let k=0;k<n;k++){
    const px = k * sx, py = y(h[k]);
    if(k) g.lineTo(px, py); else g.moveTo(px, py);
  }
  g.stroke();

  // 最近一帧
  g.fillStyle = '#4ac26b';
  g.beginPath(); g.arc((n-1) * sx, y(h[n-1]), 6, 0, 6.3); g.fill();
}

async function poll(){
  const st = await j('/state');
  if(!st){ $('status').innerHTML = '<b>本地服务断了</b>'; return; }

  const s = $('status');
  if(st.connected){
    s.classList.remove('bad');
    s.innerHTML = '<b>已连接</b> ' + st.port + (st.has_data ? '' : ' · 等待遥测…');
    $('conn').textContent = '断开';
  } else {
    s.classList.add('bad');
    s.innerHTML = st.err ? '<b>' + st.err + '</b>' : '未连接';
    $('conn').textContent = '连接';
  }

  const pg = $('page');
  if(st.page === 0){ pg.textContent = '实时页'; pg.className = 'page rt'; }
  else if(st.page === 1){ pg.textContent = '报告页'; pg.className = 'page rpt'; }
  else { pg.textContent = '--'; pg.className = 'page'; }

  const frac = Math.min(1, st.env / st.env_full);
  const fill = $('envfill');
  fill.style.width = (frac * 100).toFixed(1) + '%';
  fill.className = st.env > st.th ? 'hot' : '';
  $('envth').style.left = (st.th / st.env_full * 100).toFixed(2) + '%';
  $('envval').textContent = st.env;

  for(let k = 0; k < 4; k++) $('l'+k).classList.toggle('on', !!(st.st >> k & 1));
  $('det').textContent = '判决 ' + st.det + ' 次';

  const a = $('ack');
  if(st.pending){
    a.textContent = '已发送 ' + st.pending + '，等待板子确认…';
    a.className = 'ack wait';
  } else if(st.ack){
    a.textContent = (st.ack_ok ? '✔ ' : '✘ ') + st.ack;
    a.className = 'ack ' + (st.ack_ok ? 'ok' : 'bad');
  } else { a.textContent = ''; a.className = 'ack'; }

  drawHist(st.env_hist, st.snore_hist, st.th, st.env_full);
}

$('conn').onclick = toggleConn;
$('refresh').onclick = loadPorts;
loadPorts();
poll();
setInterval(poll, 200);
</script>
</div></body></html>
"""


# ---------------------------------------------------------------------------
# HTTP 服务
# ---------------------------------------------------------------------------
def make_server(bridge, port):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):          # 不往控制台刷访问日志
            pass

        def _send(self, body, ctype="application/json; charset=utf-8"):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode("utf-8")
            elif isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):                    # noqa: N802
            u = urlparse(self.path)
            q = parse_qs(u.query)
            p = u.path

            if p == "/":
                return self._send(PAGE, "text/html; charset=utf-8")

            if p == "/ports":
                ports = [x.device for x in list_ports.comports()]
                return self._send({"ports": ports, "auto": auto_port()})

            if p == "/state":
                return self._send(bridge.state())

            if p == "/connect":
                port_name = (q.get("port") or [""])[0]
                ok = bridge.open(port_name)
                return self._send({"ok": ok, "msg": bridge.err})

            if p == "/disconnect":
                bridge.close()
                return self._send({"ok": True})

            if p == "/cmd":
                ch = (q.get("c") or ["?"])[0][:1]
                ok, msg = bridge.send(ch)
                return self._send({"ok": ok, "msg": msg})

            self.send_error(404)

    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    return srv


def serve(port_hint=0, open_browser=True):
    bridge = Bridge()
    auto = auto_port()
    if auto:
        bridge.open(auto)

    # 端口被占用就往后顺延，最多试 20 个
    srv, port = None, port_hint or 8765
    for k in range(20):
        try:
            srv = make_server(bridge, port + k)
            port = port + k
            break
        except OSError:
            continue
    if srv is None:
        print("[!] 8765~8784 都被占用了，换一个端口：--http-port 9000")
        return 2

    url = "http://127.0.0.1:%d/" % port
    print("=" * 58)
    print(" 鼾声检测 · 电脑控制台")
    print("=" * 58)
    print(" 打开这个地址（浏览器应该已经自动打开了）：")
    print("   %s" % url)
    if bridge.connected:
        print(" 已自动连接串口：%s" % bridge.port)
    else:
        print(" 还没连上串口 —— 在页面顶部选 COM 口后点『连接』")
    print(" 关掉这个窗口（或按 Ctrl+C）就停止服务。")
    print("=" * 58)

    if open_browser:
        try:
            webbrowser.open(url)
        except Exception:                               # noqa: BLE001
            pass

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] 退出")
    finally:
        bridge.close()
        srv.server_close()
    return 0


# ---------------------------------------------------------------------------
# 命令行模式：发一条命令，等确认
# ---------------------------------------------------------------------------
def send_and_confirm(port, ch, timeout=1.5):
    try:
        ser = serial.Serial(port, 115200, timeout=0.1)
        ser.reset_input_buffer()
    except Exception as e:                              # noqa: BLE001
        return False, "打不开 %s：%s" % (port, e)

    got = []
    lock = threading.Lock()
    stop = threading.Event()

    def rd():
        buf = b""
        while not stop.is_set():
            try:
                chunk = ser.read(256)
            except Exception:                           # noqa: BLE001
                break
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                fr = parse_line(line)
                if fr is not None:
                    with lock:
                        got.append(fr)

    t = threading.Thread(target=rd, daemon=True)
    t.start()
    time.sleep(0.3)                     # 先攒几帧做基线

    with lock:
        base = next((f.cmd_cnt for f in reversed(got) if f.cmd_cnt is not None), None)

    if base is None:
        stop.set()
        ser.close()
        return False, ("没收到带 G 字段的遥测帧：板子没在跑，"
                       "或者固件还是 v3 以前（那时没有 G 字段）")

    ser.write(ch.encode("ascii"))
    ser.flush()

    deadline = time.time() + timeout
    seen = None
    while time.time() < deadline:
        with lock:
            seen = next((f for f in got
                         if f.cmd_cnt is not None and f.cmd_cnt != base), None)
        if seen:
            break
        time.sleep(0.05)

    stop.set()
    ser.close()

    if seen is None:
        return False, "命令没被确认（G 字段的命令计数没变）"
    return True, "已确认：页=%s 命令计数=%d" % (
        "报告" if seen.page else "实时", seen.cmd_cnt)


def cli_main(args):
    port = args.port or auto_port()
    if not port:
        print("[!] 没找到可用串口，请手动指定，例如: snore_ctl.py COM7 --clr")
        return 2

    if args.page:
        ch = {"report": "R", "rt": "T", "toggle": "P"}[args.page]
    elif args.clr:
        ch = "C"
    elif args.probe:
        ch = "?"
    else:
        ch = args.cmd

    print("[*] %s @115200  发送 '%s' (%s)" % (port, ch, CMDS.get(ch.upper(), "自定义")))
    ok, msg = send_and_confirm(port, ch)
    print(("    [OK] " if ok else "    [!] ") + msg)
    return 0 if ok else 1


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="鼾声检测电脑端控制台（不带参数时开网页界面）")
    ap.add_argument("port", nargs="?", default=None, help="串口号，如 COM7；省略则自动挑选")
    ap.add_argument("--cmd", default=None, help="直接发送一个字符")
    ap.add_argument("--page", choices=["report", "rt", "toggle"],
                    help="切页：report / rt / toggle")
    ap.add_argument("--clr", action="store_true", help="清零统计")
    ap.add_argument("--probe", action="store_true", help="探活，不改状态")
    ap.add_argument("--http-port", type=int, default=0, help="网页服务的端口（默认 8765）")
    ap.add_argument("--no-browser", action="store_true", help="不自动打开浏览器")
    args = ap.parse_args()

    if any([args.page, args.clr, args.probe, args.cmd]):
        return cli_main(args)
    return serve(args.http_port, open_browser=not args.no_browser)


if __name__ == "__main__":
    sys.exit(main())
