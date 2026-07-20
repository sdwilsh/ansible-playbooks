#!/usr/bin/env python3
import sys
import subprocess
import logging
import json
import re
import threading
import time
from logging.handlers import RotatingFileHandler
from typing import Tuple, Dict, Any, List, Optional

LOG_FILE: str = "/tmp/nflog/drops.log"
MAX_BYTES: int = 10 * 1024 * 1024
BACKUP_COUNT: int = 1

CONNTRACK_PATH: str = "/proc/net/nf_conntrack"
VERIFY_DELAY_SECONDS: float = 0.5
MAX_VERIFY_SECONDS: float = 3.0
VERIFIER_TICK_SECONDS: float = 0.1

KV_RE: re.Pattern = re.compile(r'(\w+)=(\S+)')

# Flows waiting for their VERIFY_DELAY_SECONDS to elapse before their first check
# against conntrack, as (captured_at, log_data) pairs, guarded by PENDING_LOCK.  A flow
# that is not yet replied on its first check is put back here rather than judged
# immediately - a Node under momentary load (e.g. many Pods restarting at once) can take
# a coredns/apiserver reply past 0.5s without the flow actually being blocked, and a
# single snapshot can't tell "slow" from "dropped".  Only once a flow has gone unreplied
# for the full MAX_VERIFY_SECONDS is it logged as dropped.
PENDING: List[Tuple[float, Dict[str, Any]]] = []
PENDING_LOCK: threading.Lock = threading.Lock()

LINE_RE: re.Pattern = re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)\s+(.+)$')

# Direct diagnostics to stderr to end up in container logs.
logging.basicConfig(
    level=logging.WARNING, 
    format='%(asctime)s [%(levelname)s] sidecar_diagnostics: %(message)s',
    handlers=[logging.StreamHandler(sys.stderr)]
)
diag_logger: logging.Logger = logging.getLogger("Diagnostics")

CACHE_TTL_SECONDS: float = 300.0
POD_CACHE: Dict[str, Dict[str, Any]] = {}

def query_kube_api_for_ip(ip_addr: str) -> Tuple[str, str]:
    diag_logger.debug(f"Cache miss for internal IP {ip_addr}. Executing live API lookup via native kubectl...")
    
    cmd: List[str] = ["kubectl", "get", "pods", "--all-namespaces", "-o", "json", "--request-timeout=2s"]
    res: subprocess.CompletedProcess = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    
    if res.returncode != 0:
        diag_logger.error(f"Kubectl API call failed with code {res.returncode}. Stderr: {res.stderr.strip()}")
        return "", ""
        
    if not res.stdout.strip():
        return "", ""

    data: Dict[str, Any] = json.loads(res.stdout)
    for item in data.get("items", []):
        status: Dict[str, Any] = item.get("status", {})
        metadata: Dict[str, Any] = item.get("metadata", {})
        
        pod_name: str = str(metadata.get("name", ""))
        namespace: str = str(metadata.get("namespace", ""))
        
        for pod_ip_obj in status.get("podIPs", []):
            if pod_ip_obj.get("ip") == ip_addr:
                return pod_name, namespace
                
    return "", ""

def resolve_pod_from_ip(ip_addr: str) -> Tuple[str, str]:
    if not ip_addr or not ip_addr.startswith("172.16."):
        return "", ""
        
    current_time: float = time.time()
    if ip_addr in POD_CACHE:
        cache_entry: Dict[str, Any] = POD_CACHE[ip_addr]
        if current_time < cache_entry["expires"]:
            return cache_entry["pod"], cache_entry["ns"]
            
    pod_name, namespace = query_kube_api_for_ip(ip_addr)
    POD_CACHE[ip_addr] = {
        "pod": pod_name,
        "ns": namespace,
        "expires": current_time + CACHE_TTL_SECONDS
    }
    
    if pod_name:
        diag_logger.debug(f"Successfully mapped and cached {ip_addr} -> {namespace}/{pod_name}")
    return pod_name, namespace

def parse_endpoint(endpoint_str: str) -> Tuple[str, str]:
    """Safely extracts IP and Port for both IPv4 and IPv6 string styles."""
    endpoint_str = endpoint_str.rstrip(':')
    if '.' in endpoint_str and ':' not in endpoint_str:
        parts: List[str] = endpoint_str.rsplit('.', 1)
        if len(parts) == 2:
            return str(parts[0]), str(parts[1])
    return endpoint_str, ""

# kube-router logs a packet via NFLOG whenever the NetworkPolicy chain it happens to
# evaluate first doesn't match, even if a later chain for the same Pod goes on to accept
# the packet (see https://github.com/k3s-io/k3s/issues/8008,
# https://github.com/k3s-io/k3s/issues/9032). Verify against conntrack, which reflects
# what the kernel actually did with the packet, rather than trusting the log.
#
# Match on the Pod's own (protocol, src, sport) rather than reconstructing a NATed
# 4-tuple.  Two independent NAT layers can each break a dest-based match: NFLOG reports
# the post-DNAT dest_ip (it taps the Pod's own firewall chain after any Service DNAT),
# which never lines up with conntrack's original-direction dst (pre-DNAT); and whenever
# the destination is outside the Pod network - the apiserver's Node IP via the
# 172.17.0.1 hairpin, or a real LAN host like a Garage Node or a camera - flannel also
# SNATs/masquerades the packet, so conntrack's reply-direction dst becomes the *Node's*
# real IP rather than the Pod's, which never lines up with the Pod IP either.  This was
# confirmed live: Pods successfully reaching the apiserver and Garage via that hairpin
# were logged as "dropped" on every single request, because the reply tuple's dst was
# the Node's masqueraded IP, not the Pod's.  src/sport is the one pair NFLOG and
# conntrack's original-direction tuple always agree on, since NFLOG taps before any NAT
# rewrites the source, so anchor there instead.
#
# SYN_SENT (TCP) / UNREPLIED (UDP) mean conntrack created the entry but has not yet seen
# a reply. conntrack can hold tens of thousands of entries and this cluster sees
# hundreds of NFLOG events a minute, so checks are batched: the whole table is parsed
# once per tick into an index, and every flow due for a check is looked up against that
# single pass, rather than each flow re-scanning the entire table on its own thread.

def build_conntrack_index() -> Optional[Dict[Tuple[str, str, str], bool]]:
    index: Dict[Tuple[str, str, str], bool] = {}
    try:
        with open(CONNTRACK_PATH, "r") as f:
            for line in f:
                fields: List[str] = line.split()
                if len(fields) < 3:
                    continue
                protocol: str = fields[2]
                replied: bool = "SYN_SENT" not in line and "UNREPLIED" not in line
                seen: Dict[str, int] = {}
                original: Dict[str, str] = {}
                for key, val in KV_RE.findall(line):
                    if key not in ("src", "sport"):
                        continue
                    seen[key] = seen.get(key, 0) + 1
                    if seen[key] == 1:
                        original[key] = val
                if len(original) == 2:
                    flow_key: Tuple[str, str, str] = (protocol, original["src"], original["sport"])
                    index[flow_key] = index.get(flow_key, False) or replied
    except OSError:
        diag_logger.exception(f"Failed to read {CONNTRACK_PATH} for conntrack verification")
        return None
    return index

def verifier_loop(logger: logging.Logger) -> None:
    while True:
        time.sleep(VERIFIER_TICK_SECONDS)
        now: float = time.time()

        due: List[Tuple[float, Dict[str, Any]]] = []
        with PENDING_LOCK:
            still_pending: List[Tuple[float, Dict[str, Any]]] = []
            for captured_at, log_data in PENDING:
                if now - captured_at >= VERIFY_DELAY_SECONDS:
                    due.append((captured_at, log_data))
                else:
                    still_pending.append((captured_at, log_data))
            PENDING[:] = still_pending

        if not due:
            continue

        index: Optional[Dict[Tuple[str, str, str], bool]] = build_conntrack_index()
        undecided: List[Tuple[float, Dict[str, Any]]] = []
        for captured_at, log_data in due:
            flow_key = (log_data["protocol"], log_data["src_ip"], log_data["src_port"])
            replied: Optional[bool] = index.get(flow_key) if index is not None else None
            if replied:
                continue
            if now - captured_at < MAX_VERIFY_SECONDS:
                undecided.append((captured_at, log_data))
                continue
            log_data["verdict"] = "unknown" if index is None else "dropped"
            logger.info(json.dumps(log_data))

        if undecided:
            with PENDING_LOCK:
                PENDING.extend(undecided)

def setup_file_logger() -> logging.Logger:
    logger: logging.Logger = logging.getLogger("AlloyJsonLogger")
    logger.setLevel(logging.INFO)
    
    logger.propagate = False 
    
    handler: RotatingFileHandler = RotatingFileHandler(LOG_FILE, maxBytes=MAX_BYTES, backupCount=BACKUP_COUNT)
    handler.setFormatter(logging.Formatter('%(message)s'))
    logger.addHandler(handler)
    return logger

def main() -> None:
    logger: logging.Logger = setup_file_logger()
    diag_logger.debug("Initializing background netfilter capture sidecar...")

    threading.Thread(target=verifier_loop, args=(logger,), daemon=True).start()

    cmd: List[str] = ["tcpdump", "-l", "-i", "nflog:100", "-n", "-tttt"]
    process: subprocess.Popen = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    try:
        while True:
            line: str = process.stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line or " > " not in line: 
                continue
                
            match: re.Match = LINE_RE.match(line)
            if not match: 
                continue
            
            timestamp, payload = match.groups()
            tokens: List[str] = payload.split()
            if len(tokens) < 4: 
                continue
            
            try:
                src_token: str = tokens[1]
                dst_token: str = tokens[3]
                
                src_ip, src_port = parse_endpoint(src_token)
                dest_ip, dest_port = parse_endpoint(dst_token)
                
                src_pod, src_ns = resolve_pod_from_ip(src_ip)
                dest_pod, dest_ns = resolve_pod_from_ip(dest_ip)

                # tcpdump always prints "Flags [...]" first for TCP, even when it also
                # decodes an application-layer protocol on top (e.g. HTTP).  UDP has no
                # such fixed marker: unrecognized UDP prints "UDP, length N", but a
                # well-known port like 53 gets fully decoded instead (e.g. "12345+ A?
                # example.com. (29)"), so checking for a literal "UDP" token misses it.
                protocol: str = "tcp" if len(tokens) > 4 and tokens[4] == "Flags" else "udp"

                log_data: Dict[str, Any] = {
                    "raw_time": timestamp,
                    "protocol": protocol,
                    "src_ip": src_ip, "src_port": src_port, "src_pod": src_pod, "src_namespace": src_ns,
                    "dest_ip": dest_ip, "dest_port": dest_port, "dest_pod": dest_pod, "dest_namespace": dest_ns,
                    "packet_details": " ".join(tokens[4:])
                }

                with PENDING_LOCK:
                    PENDING.append((time.time(), log_data))
            except Exception:
                diag_logger.exception("A fatal parsing exception occurred while processing a log stream line.")
    except KeyboardInterrupt: 
        process.terminate()

if __name__ == '__main__': 
    main()
