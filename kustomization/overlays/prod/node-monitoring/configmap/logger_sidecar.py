#!/usr/bin/env python3
import sys
import subprocess
import logging
import json
import re
import time
from logging.handlers import RotatingFileHandler
from typing import Tuple, Dict, Any, List

LOG_FILE: str = "/tmp/nflog/drops.log"
MAX_BYTES: int = 10 * 1024 * 1024
BACKUP_COUNT: int = 1

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
            return str(parts[0]), str(parts[1]) # FIXED: Returns actual string tokens, not the whole array
    return endpoint_str, ""

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
                
                log_data: Dict[str, Any] = {
                    "raw_time": timestamp,
                    "src_ip": src_ip, "src_port": src_port, "src_pod": src_pod, "src_namespace": src_ns,
                    "dest_ip": dest_ip, "dest_port": dest_port, "dest_pod": dest_pod, "dest_namespace": dest_ns,
                    "packet_details": " ".join(tokens[4:])
                }
                
                logger.info(json.dumps(log_data))
            except Exception:
                diag_logger.exception("A fatal parsing exception occurred while processing a log stream line.")
    except KeyboardInterrupt: 
        process.terminate()

if __name__ == '__main__': 
    main()
