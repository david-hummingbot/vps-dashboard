#!/usr/bin/env python3
"""
VPS Monitor Agent — collects host metrics and Docker container status,
then POSTs them to the dashboard server every REPORT_INTERVAL seconds.

Environment variables:
  DASHBOARD_URL     http://100.x.x.x:8080   (required — Tailscale IP of server)
  API_KEY           changeme                 (must match server API_KEY)
  NODE_NAME         my-server               (defaults to hostname)
  REPORT_INTERVAL   30                      (seconds between reports)
"""

import os
import time
import socket
import logging
import httpx
import psutil

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

DASHBOARD_URL    = os.environ["DASHBOARD_URL"].rstrip("/")
API_KEY          = os.environ.get("API_KEY", "changeme")
NODE_NAME        = os.environ.get("NODE_NAME", socket.gethostname())
REPORT_INTERVAL  = int(os.environ.get("REPORT_INTERVAL", "30"))


def get_docker_containers():
    try:
        import docker
        client = docker.DockerClient(base_url="unix://var/run/docker.sock")
        containers = client.containers.list(all=True)
        result = []
        for c in containers:
            result.append({
                "name":   c.name,
                "id":     c.short_id,
                "image":  c.image.tags[0] if c.image.tags else c.image.short_id,
                "status": c.status,
                "ports":  list(c.ports.keys()) if c.ports else [],
            })
        return result
    except Exception as e:
        log.warning(f"Docker unavailable: {e}")
        return []


def get_network_counters():
    try:
        counters = psutil.net_io_counters()
        return counters.bytes_recv / (1024 * 1024), counters.bytes_sent / (1024 * 1024)
    except Exception:
        return 0.0, 0.0


def collect_metrics():
    cpu     = psutil.cpu_percent(interval=1)
    mem     = psutil.virtual_memory()
    disk    = psutil.disk_usage("/")
    rx, tx  = get_network_counters()
    uptime  = time.time() - psutil.boot_time()

    try:
        load = list(os.getloadavg())
    except AttributeError:
        load = [0.0, 0.0, 0.0]

    return {
        "node_name":      NODE_NAME,
        "cpu_percent":    cpu,
        "ram_percent":    mem.percent,
        "ram_used_mb":    mem.used  / (1024 * 1024),
        "ram_total_mb":   mem.total / (1024 * 1024),
        "disk_percent":   disk.percent,
        "disk_used_gb":   disk.used  / (1024 ** 3),
        "disk_total_gb":  disk.total / (1024 ** 3),
        "network_rx_mb":  rx,
        "network_tx_mb":  tx,
        "uptime_seconds": uptime,
        "load_avg":       load,
        "containers":     get_docker_containers(),
    }


def send_metrics(payload: dict):
    url = f"{DASHBOARD_URL}/api/metrics"
    with httpx.Client(timeout=10) as client:
        resp = client.post(url, json=payload, headers={"X-API-Key": API_KEY})
        resp.raise_for_status()


def main():
    log.info(f"Agent starting — node={NODE_NAME} server={DASHBOARD_URL} interval={REPORT_INTERVAL}s")
    backoff = REPORT_INTERVAL

    while True:
        try:
            payload = collect_metrics()
            send_metrics(payload)
            log.info(
                f"Sent — CPU={payload['cpu_percent']:.1f}% "
                f"RAM={payload['ram_percent']:.1f}% "
                f"Disk={payload['disk_percent']:.1f}% "
                f"Containers={len(payload['containers'])}"
            )
            backoff = REPORT_INTERVAL
        except KeyboardInterrupt:
            break
        except Exception as e:
            log.error(f"Failed to send metrics: {e}")
            backoff = min(backoff * 2, 300)
            log.info(f"Retrying in {backoff}s")

        time.sleep(backoff)


if __name__ == "__main__":
    main()
