#!/usr/bin/env python3
import json
import logging
import os
import socket
import struct
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from typing import IO, Any, Iterator, NamedTuple

LOG_FILE: str = "/tmp/nflog/drops.log"
MAX_BYTES: int = 10 * 1024 * 1024
BACKUP_COUNT: int = 1

LINKTYPE_NFLOG: int = 239
NFULA_PAYLOAD: int = 9
NFULA_PREFIX: int = 10
class PcapFormat(NamedTuple):
    byte_order: str
    fraction_per_usec: int


PCAP_MAGICS: dict[bytes, PcapFormat] = {
    b"\xd4\xc3\xb2\xa1": PcapFormat("<", 1),
    b"\xa1\xb2\xc3\xd4": PcapFormat(">", 1),
    b"\x4d\x3c\xb2\xa1": PcapFormat("<", 1000),
    b"\xa1\xb2\x3c\x4d": PcapFormat(">", 1000),
}

# Direct diagnostics to stderr to end up in container logs.
logging.basicConfig(
    level=logging.WARNING,
    format='%(asctime)s [%(levelname)s] sidecar_diagnostics: %(message)s',
    handlers=[logging.StreamHandler(sys.stderr)]
)
diag_logger: logging.Logger = logging.getLogger("Diagnostics")

POD_CACHE_REFRESH_SECONDS: float = 300.0
POD_IP_MAP: dict[str, tuple[str, str]] = {}
POD_IP_MAP_LOCK: threading.Lock = threading.Lock()


@dataclass(frozen=True)
class NflogPacket:
    time: datetime
    prefix: str | None
    payload: bytes


@dataclass(frozen=True)
class Flow:
    protocol: str
    src_ip: str
    src_port: str
    dest_ip: str
    dest_port: str
    details: str


def fetch_pod_ip_map() -> dict[str, tuple[str, str]] | None:
    cmd: list[str] = ["kubectl", "get", "pods", "--all-namespaces", "-o", "json", "--request-timeout=10s"]
    res: subprocess.CompletedProcess[str] = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    if res.returncode != 0:
        diag_logger.error(f"Kubectl API call failed with code {res.returncode}. Stderr: {res.stderr.strip()}")
        return None

    if not res.stdout.strip():
        return None

    data: dict[str, Any] = json.loads(res.stdout)
    ip_map: dict[str, tuple[str, str]] = {}
    for item in data.get("items", []):
        status: dict[str, Any] = item.get("status", {})
        metadata: dict[str, Any] = item.get("metadata", {})

        pod_name: str = str(metadata.get("name", ""))
        namespace: str = str(metadata.get("namespace", ""))

        for pod_ip_obj in status.get("podIPs", []):
            ip: str | None = pod_ip_obj.get("ip")
            if ip:
                ip_map[ip] = (pod_name, namespace)

    return ip_map

# A single background thread refreshes a full IP -> (pod, namespace) map on a timer, instead of
# fetching one Pod's IP on each cache miss.  The Kubernetes API has no way to fetch a Pod by IP,
# so a per-IP lookup still downloads every Pod on the cluster.  On a per-miss cache, that cost
# lands on whichever thread hits the miss - the capture loop, for every unresolved IP in a packet.
def pod_cache_refresh_loop() -> None:
    while True:
        ip_map: dict[str, tuple[str, str]] | None = fetch_pod_ip_map()
        if ip_map is not None:
            with POD_IP_MAP_LOCK:
                POD_IP_MAP.clear()
                POD_IP_MAP.update(ip_map)
        time.sleep(POD_CACHE_REFRESH_SECONDS)

def resolve_pod_from_ip(ip_addr: str) -> tuple[str, str]:
    if not ip_addr or not ip_addr.startswith("172.16."):
        return "", ""

    with POD_IP_MAP_LOCK:
        return POD_IP_MAP.get(ip_addr, ("", ""))

def read_exact(stream: IO[bytes], size: int) -> bytes | None:
    data: bytes = stream.read(size)
    return data if len(data) == size else None

def parse_nflog(record: bytes, order: str) -> tuple[str | None, bytes]:
    prefix: str | None = None
    payload: bytes = b""
    # TLVs start after the 4-byte nflog header.  Their length and type use the
    # byte order of the capture host, which is also the pcap header byte order.
    offset: int = 4
    while offset + 4 <= len(record):
        length, tlv_type = struct.unpack_from(order + "HH", record, offset)
        if length < 4:
            break
        value: bytes = record[offset + 4:offset + length]
        if tlv_type == NFULA_PREFIX:
            prefix = value.split(b"\0", 1)[0].decode("utf-8", "replace")
        elif tlv_type == NFULA_PAYLOAD:
            payload = value
        offset += (length + 3) & ~3
    return prefix, payload

def read_pcap(stream: IO[bytes]) -> Iterator[NflogPacket]:
    header: bytes | None = read_exact(stream, 24)
    if header is None:
        return
    if header[:4] not in PCAP_MAGICS:
        raise ValueError(f"not a pcap stream: magic {header[:4].hex()}")
    pcap_format: PcapFormat = PCAP_MAGICS[header[:4]]
    order: str = pcap_format.byte_order
    per_usec: int = pcap_format.fraction_per_usec
    linktype: int = struct.unpack_from(order + "I", header, 20)[0]
    if linktype != LINKTYPE_NFLOG:
        raise ValueError(f"pcap link type is {linktype}, not NFLOG")
    while True:
        record_header: bytes | None = read_exact(stream, 16)
        if record_header is None:
            return
        ts_sec, ts_frac, incl_len, _ = struct.unpack(order + "IIII", record_header)
        record: bytes | None = read_exact(stream, incl_len)
        if record is None:
            return
        prefix, payload = parse_nflog(record, order)
        when: datetime = datetime.fromtimestamp(ts_sec, timezone.utc).replace(microsecond=min(ts_frac // per_usec, 999999))
        yield NflogPacket(when, prefix, payload)

def is_policy_reject(packet: NflogPacket) -> bool:
    # kube-router logs "DROP by policy <ns>/<name>" when one policy does not
    # match, and a later policy can still accept the packet (k3s-io/k3s#9032).
    # Only the log just before the pod chain REJECT has no prefix.
    return not packet.prefix

def tcp_flags(flags: int) -> str:
    letters: list[tuple[int, str]] = [(0x01, "F"), (0x02, "S"), (0x04, "R"), (0x08, "P"), (0x10, "."), (0x20, "U"), (0x40, "E"), (0x80, "W")]
    return "".join(letter for bit, letter in letters if flags & bit) or "none"

def decode_flow(payload: bytes) -> Flow | None:
    if not payload:
        return None
    version: int = payload[0] >> 4
    if version == 4 and len(payload) >= 20:
        header_len: int = (payload[0] & 0x0f) * 4
        ip_len: int = struct.unpack_from("!H", payload, 2)[0]
        proto: int = payload[9]
        src: str = socket.inet_ntop(socket.AF_INET, payload[12:16])
        dst: str = socket.inet_ntop(socket.AF_INET, payload[16:20])
        l4: bytes = payload[header_len:ip_len]
    elif version == 6 and len(payload) >= 40:
        proto = payload[6]
        src = socket.inet_ntop(socket.AF_INET6, payload[8:24])
        dst = socket.inet_ntop(socket.AF_INET6, payload[24:40])
        l4 = payload[40:40 + struct.unpack_from("!H", payload, 4)[0]]
    else:
        return None

    if proto == 6 and len(l4) >= 20:
        sport, dport, seq, ack, offset_flags, win = struct.unpack_from("!HHIIHH", l4)
        flags: int = offset_flags & 0xff
        ack_text: str = f", ack {ack}" if flags & 0x10 else ""
        data_len: int = len(l4) - (offset_flags >> 12) * 4
        return Flow("tcp", src, str(sport), dst, str(dport),
                    f"Flags [{tcp_flags(flags)}], seq {seq}{ack_text}, win {win}, length {data_len}")
    if proto == 17 and len(l4) >= 8:
        sport, dport, udp_len = struct.unpack_from("!HHH", l4)
        return Flow("udp", src, str(sport), dst, str(dport), f"UDP, length {udp_len - 8}")
    if proto in (1, 58) and len(l4) >= 2:
        name: str = "icmp" if proto == 1 else "icmp6"
        return Flow(name, src, "", dst, "", f"{name.upper()} type {l4[0]}, code {l4[1]}, length {len(l4)}")
    return Flow(f"ip-proto-{proto}", src, "", dst, "", f"length {len(l4)}")

def drop_record(packet: NflogPacket, node: str) -> dict[str, str] | None:
    if not is_policy_reject(packet):
        return None
    flow: Flow | None = decode_flow(packet.payload)
    if flow is None:
        diag_logger.warning(f"Undecodable NFLOG payload: {packet.payload[:64].hex()}")
        return None
    src_pod, src_ns = resolve_pod_from_ip(flow.src_ip)
    dest_pod, dest_ns = resolve_pod_from_ip(flow.dest_ip)
    return {
        "raw_time": packet.time.strftime("%Y-%m-%d %H:%M:%S.%f"),
        "protocol": flow.protocol,
        "src_ip": flow.src_ip, "src_port": flow.src_port, "src_pod": src_pod, "src_namespace": src_ns,
        "dest_ip": flow.dest_ip, "dest_port": flow.dest_port, "dest_pod": dest_pod, "dest_namespace": dest_ns,
        "packet_details": flow.details,
        "verdict": "dropped",
        "node": node,
    }

def setup_file_logger() -> logging.Logger:
    logger: logging.Logger = logging.getLogger("AlloyJsonLogger")
    logger.setLevel(logging.INFO)

    logger.propagate = False

    handler: RotatingFileHandler = RotatingFileHandler(LOG_FILE, maxBytes=MAX_BYTES, backupCount=BACKUP_COUNT)
    handler.setFormatter(logging.Formatter('%(message)s'))
    logger.addHandler(handler)
    return logger

def main() -> None:
    node: str = os.environ["NODE_NAME"]
    logger: logging.Logger = setup_file_logger()

    threading.Thread(target=pod_cache_refresh_loop, daemon=True).start()

    cmd: list[str] = ["tcpdump", "-i", "nflog:100", "-U", "-w", "-"]
    process: subprocess.Popen[bytes] = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    assert process.stdout is not None

    try:
        for packet in read_pcap(process.stdout):
            try:
                record: dict[str, str] | None = drop_record(packet, node)
                if record is not None:
                    logger.info(json.dumps(record))
            except Exception:
                diag_logger.exception("A parsing exception occurred while processing an NFLOG packet.")
    except KeyboardInterrupt:
        process.terminate()

if __name__ == '__main__':
    main()
