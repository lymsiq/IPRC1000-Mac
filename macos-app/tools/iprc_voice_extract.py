#!/usr/bin/env python3
"""IPRC1000 语音提取 / 实时跟随器

两种用途
--------
1) **离线提取**（验证用）：把 PacketLogger 抓的包里的音频抠成 WAV
       python3 iprc_voice_extract.py capture.pklg -o voice.wav

2) **实时跟随**（配合 `IPRC1000Adapter --voice-udp 31680` 做语音输入）
       python3 iprc_voice_extract.py --follow /tmp/iprc.pklg --udp 127.0.0.1:31680
   PacketLogger 一边录、这里一边解析，解出的 16 kHz PCM 通过 UDP 直接灌进 BlackHole。

背景（为什么需要它）
------------------
macOS 的 HID 层会按报告描述符解析，把遥控器那 653 字节的音频报告直接丢掉，
应用层拿不到（见 docs/MACOS_VOICE.md）。唯一能拿到的是 **HCI 层抓包**。
音频帧格式（来自 lymsiq/IPRC1000-Adapter 的真机逆向）：
    L2CAP 负载 653 字节 = 13 字节帧头 + 640 字节音频（320 × int16 LE @ 16 kHz）
    帧头：A1 F7 01 <seq> 00 81 00 <cnt> 00 00 00 40 01
ACL 上拆两片：首片 dlen=344（含 4 字节 L2CAP 头） + 续片 dlen=313。

⚠ 前提：必须先用 Apple 的「Bluetooth 日志描述文件」启用蓝牙抓包，否则抓到的文件是空的。
"""

import argparse
import os
import socket
import struct
import sys
import time

FRAME_LEN = 653
HDR = 13
PAYLOAD = 640
HEADER_TAIL = bytes([0x00, 0x00, 0x00, 0x40, 0x01])
FRAG1 = 344
FRAG2 = 313


# ───────────────────────── 通用 ─────────────────────────

def find_audio_offset(buf: memoryview, start: int = 0, limit: int = 48):
    for i in range(start, min(start + limit, len(buf) - 5)):
        if bytes(buf[i:i + 5]) == HEADER_TAIL and i >= 3 and buf[i - 3] == 0x81:
            return i + 5
    return None


def write_wav(path, pcm_bytes, rate=16000):
    data = bytearray()
    data += b"RIFF" + struct.pack("<I", 36 + len(pcm_bytes)) + b"WAVE"
    data += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    data += b"data" + struct.pack("<I", len(pcm_bytes))
    data += pcm_bytes
    with open(path, "wb") as fh:
        fh.write(data)


# ───────────────────────── btsnoop 流式解析 ─────────────────────────

class BtsnoopFollower:
    """增量解析 btsnoop（PacketLogger 的 .pklg）流，回调每帧 PCM。"""

    def __init__(self, on_pcm):
        self.buf = bytearray()
        self.pending = bytearray()
        self.datalink = 1002
        self.need_header = True
        self.on_pcm = on_pcm
        self.frames = 0
        self.acl = 0
        self.other = 0

    def feed(self, chunk: bytes):
        self.buf += chunk
        if self.need_header:
            if len(self.buf) < 16:
                return
            if bytes(self.buf[0:8]) == b"btsnoop\x00":
                self.datalink = struct.unpack_from(">I", self.buf, 12)[0]
            else:
                self.datalink = 1002      # 当作无容器的裸 HCI 流
                self.need_header = False
                self._drain()
                return
            self.need_header = False
            del self.buf[0:16]
        self._drain()

    def _drain(self):
        while len(self.buf) >= 24:
            _orig, incl = struct.unpack_from(">II", self.buf, 0)
            if len(self.buf) < 24 + incl:
                break
            pkt = bytes(self.buf[24:24 + incl])
            del self.buf[0:24 + incl]
            self._handle_hci(pkt)

    def _handle_hci(self, pkt: bytes):
        if self.datalink == 1002:
            if not pkt or pkt[0] != 0x02:
                self.other += 1
                return
            pkt = pkt[1:]
        if len(pkt) < 4:
            return
        hf = struct.unpack_from("<H", pkt, 0)[0]
        dlen = struct.unpack_from("<H", pkt, 2)[0]
        body = pkt[4:4 + dlen]
        pb = (hf >> 12) & 0x3
        self.acl += 1
        if pb in (0, 2):
            self.pending = bytearray(body)
        elif pb == 1:
            self.pending += body
        else:
            return
        if len(self.pending) >= 4:
            l2len = struct.unpack_from("<H", self.pending, 0)[0]
            if l2len == FRAME_LEN and len(self.pending) >= 4 + FRAME_LEN:
                payload = bytes(self.pending[4:4 + FRAME_LEN])
                off = find_audio_offset(memoryview(payload))
                if off is not None and off + PAYLOAD <= len(payload):
                    self.on_pcm(payload[off:off + PAYLOAD])
                    self.frames += 1
                self.pending = bytearray(self.pending[4 + FRAME_LEN:])


class RawFollower:
    """不依赖容器：在字节流里按帧头签名 + 661 字节固定间距抠帧。"""

    def __init__(self, on_pcm):
        self.buf = bytearray()
        self.on_pcm = on_pcm
        self.frames = 0

    def feed(self, chunk: bytes):
        self.buf += chunk
        sig = b"\xa1\xf7\x01"
        while True:
            idx = self.buf.find(sig)
            if idx < 0:
                # 保留末尾几个字节，避免签名被切断
                if len(self.buf) > 8:
                    del self.buf[0:len(self.buf) - 8]
                return
            if idx + 661 > len(self.buf):
                if idx > 0:
                    del self.buf[0:idx]
                return
            if bytes(self.buf[idx + 4:idx + 7]) != bytes([0x00, 0x81, 0x00]) \
                    or bytes(self.buf[idx + 8:idx + 13]) != HEADER_TAIL:
                del self.buf[0:idx + 3]
                continue
            payload = bytes(self.buf[idx:idx + FRAG1]) + \
                bytes(self.buf[idx + FRAG1 + 4:idx + FRAG1 + 4 + FRAG2])
            del self.buf[0:idx + 661]
            off = find_audio_offset(memoryview(payload))
            if off is not None and off + PAYLOAD <= len(payload):
                self.on_pcm(payload[off:off + PAYLOAD])
                self.frames += 1


# ───────────────────────── 离线模式 ─────────────────────────

def parse_btsnoop_bytes(data: bytes):
    pcm = bytearray()
    frames = 0
    pending = bytearray()
    if data[:8] != b"btsnoop\x00":
        return None
    datalink = struct.unpack_from(">I", data, 12)[0]
    off = 16
    while off + 24 <= len(data):
        _o, incl = struct.unpack_from(">II", data, off)
        off += 24
        if incl == 0 or off + incl > len(data):
            break
        pkt = data[off:off + incl]
        off += incl
        if datalink == 1002:
            if not pkt or pkt[0] != 0x02:
                continue
            pkt = pkt[1:]
        if len(pkt) < 4:
            continue
        hf = struct.unpack_from("<H", pkt, 0)[0]
        dlen = struct.unpack_from("<H", pkt, 2)[0]
        pb = (hf >> 12) & 0x3
        if pb in (0, 2):
            pending = bytearray(pkt[4:4 + dlen])
        elif pb == 1:
            pending += pkt[4:4 + dlen]
        else:
            continue
        if len(pending) >= 4:
            l2len = struct.unpack_from("<H", pending, 0)[0]
            if l2len == FRAME_LEN and len(pending) >= 4 + FRAME_LEN:
                payload = bytes(pending[4:4 + FRAME_LEN])
                o = find_audio_offset(memoryview(payload))
                if o is not None and o + PAYLOAD <= len(payload):
                    pcm += payload[o:o + PAYLOAD]
                    frames += 1
                pending = bytearray(pending[4 + FRAME_LEN:])
    return frames, bytes(pcm)


def parse_scan_bytes(data: bytes):
    pcm = bytearray()
    frames = 0
    starts = []
    idx = 0
    while True:
        idx = data.find(b"\xa1\xf7\x01", idx)
        if idx < 0:
            break
        if bytes(data[idx + 4:idx + 7]) == bytes([0x00, 0x81, 0x00]) \
                and bytes(data[idx + 8:idx + 13]) == HEADER_TAIL:
            starts.append(idx)
        idx += 1
    for k, o in enumerate(starts):
        if o + 661 > len(data):
            break
        gap = (starts[k + 1] - o) if k + 1 < len(starts) else 661
        if gap < 657:
            continue
        payload = data[o:o + FRAG1] + data[o + FRAG1 + 4:o + FRAG1 + 4 + FRAG2]
        off = find_audio_offset(memoryview(payload))
        if off is None:
            continue
        pcm += payload[off:off + PAYLOAD]
        frames += 1
    return frames, bytes(pcm), {"signatures": len(starts)}


# ───────────────────────── 实时跟随 ─────────────────────────

def follow(path, udp_addr, wav_path, poll=0.1, verbose=True):
    sock = None
    if udp_addr:
        host, _, port = udp_addr.partition(":")
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        target = (host or "127.0.0.1", int(port or 31680))
        if verbose:
            print(f"[i] UDP → {target[0]}:{target[1]}（每帧 640 字节 / 16 kHz PCM）", flush=True)

    wav = None
    pcm_total = 0
    if wav_path:
        wav = open(wav_path + ".raw", "wb")

    def on_pcm(pcm: bytes):
        nonlocal pcm_total
        pcm_total += len(pcm)
        if sock:
            sock.sendto(pcm, target)
        if wav:
            wav.write(pcm)
            wav.flush()

    follower = BtsnoopFollower(on_pcm)
    raw_follower = RawFollower(on_pcm) if not path else None

    # 等文件出现
    waited = 0.0
    while not os.path.exists(path):
        if waited > 30:
            print(f"[!] 等了 30 秒也没看到 {path}", flush=True)
            return 3
        time.sleep(0.2)
        waited += 0.2

    offset = 0
    # 若是已有内容的文件，默认从头跟（想只跟新数据可自行截断文件）
    print(f"[i] 开始跟随 {path}（每 {int(poll*1000)} ms 检查一次）", flush=True)
    last_report = time.time()
    last_size = -1
    while True:
        try:
            size = os.path.getsize(path)
        except OSError:
            size = last_size
        if size != last_size:
            with open(path, "rb") as fh:
                fh.seek(offset)
                chunk = fh.read()
                offset = fh.tell()
            if chunk:
                follower.feed(chunk)
            last_size = size

        now = time.time()
        if now - last_report > 5:
            last_report = now
            print(f"[i] 音频帧 {follower.frames}  (约 {pcm_total/2/16000:.2f} 秒)"
                  f"  ACL包 {follower.acl}  其他 {follower.other}  文件 {size}B", flush=True)
        time.sleep(poll)


# ───────────────────────── main ─────────────────────────

def main():
    ap = argparse.ArgumentParser(description="IPRC1000 语音提取 / 实时跟随器")
    ap.add_argument("capture", nargs="?", help="抓包文件（.pklg / btsnoop）")
    ap.add_argument("-o", "--out", default="iprc1000-voice.wav", help="离线模式输出 WAV")
    ap.add_argument("--scan", action="store_true", help="强制使用签名扫描模式")
    ap.add_argument("--follow", action="store_true", help="实时跟随模式（配合 --udp）")
    ap.add_argument("--udp", default=None, help="跟随模式：把 PCM 发到 host:port")
    ap.add_argument("--poll", type=float, default=0.1, help="跟随轮询间隔（秒）")
    args = ap.parse_args()

    if args.follow:
        if not args.capture:
            print("[!] --follow 需要给出抓包文件路径")
            return 1
        try:
            return follow(args.capture, args.udp, args.out, args.poll)
        except KeyboardInterrupt:
            print("\n[i] 已停止跟随")
            return 0

    if not args.capture:
        print("[!] 请给出抓包文件，或用 --follow <文件> --udp host:port")
        return 1

    with open(args.capture, "rb") as fh:
        data = fh.read()
    print(f"[i] 读取 {args.capture}: {len(data)} 字节")

    result = None
    if not args.scan:
        result = parse_btsnoop_bytes(data)
        if result is None:
            print("[i] 不是 btsnoop 容器，回退到签名扫描模式")
    if result is None:
        result = parse_scan_bytes(data)

    frames, pcm = result[0], result[1]
    if len(result) > 2:
        print(f"[i] 统计：{result[2]}")
    print(f"[i] 解析到音频帧 {frames} 帧 = {len(pcm)} 字节 = {len(pcm)/2/16000:.2f} 秒")
    if frames == 0:
        print("[!] 没找到音频帧。请确认：① 抓包时确实按住麦克风键说了话；")
        print("    ② 抓的是遥控器连本机时的 HCI 日志；③ 蓝牙日志描述文件已生效。")
        return 3
    write_wav(args.out, pcm)
    print(f"[✓] 已写出 {args.out}（16 kHz 单声道）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
