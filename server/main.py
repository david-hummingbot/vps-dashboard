from fastapi import FastAPI, HTTPException, Depends, Security
from fastapi.security import APIKeyHeader
from fastapi.staticfiles import StaticFiles
from fastapi.responses import JSONResponse
from contextlib import asynccontextmanager
import asyncio
import os
import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from database import get_db, init_db, Node, Metric, Alert, SessionLocal
from notifications import notify_discord, notify_telegram, NotificationConfig
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

API_KEY = os.environ.get("API_KEY", "changeme")
OFFLINE_THRESHOLD = int(os.environ.get("OFFLINE_THRESHOLD_SECONDS", "120"))
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL_SECONDS", "60"))
ALERT_CPU_THRESHOLD = float(os.environ.get("ALERT_CPU_THRESHOLD", "90"))
ALERT_RAM_THRESHOLD = float(os.environ.get("ALERT_RAM_THRESHOLD", "90"))
ALERT_DISK_THRESHOLD = float(os.environ.get("ALERT_DISK_THRESHOLD", "90"))

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

notification_config = NotificationConfig(
    discord_webhook=os.environ.get("DISCORD_WEBHOOK_URL"),
    telegram_bot_token=os.environ.get("TELEGRAM_BOT_TOKEN"),
    telegram_chat_id=os.environ.get("TELEGRAM_CHAT_ID"),
)


async def verify_api_key(api_key: str = Security(api_key_header)):
    if api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return api_key


class MetricsPayload(BaseModel):
    node_name: str
    cpu_percent: float
    ram_percent: float
    ram_used_mb: float
    ram_total_mb: float
    disk_percent: float
    disk_used_gb: float
    disk_total_gb: float
    network_rx_mb: float
    network_tx_mb: float
    uptime_seconds: float
    load_avg: list[float]
    containers: list[dict]


async def monitor_loop():
    while True:
        await asyncio.sleep(CHECK_INTERVAL)
        db = SessionLocal()
        try:
            threshold = datetime.now(timezone.utc) - timedelta(seconds=OFFLINE_THRESHOLD)
            nodes = db.query(Node).all()
            for node in nodes:
                last_seen = node.last_seen
                if last_seen and last_seen.tzinfo is None:
                    last_seen = last_seen.replace(tzinfo=timezone.utc)
                is_online = bool(last_seen and last_seen > threshold)
                if node.is_online and not is_online:
                    node.is_online = False
                    db.add(Alert(
                        node_id=node.id, node_name=node.name,
                        alert_type="node_offline",
                        message=f"Node '{node.name}' went offline (last seen: {node.last_seen})",
                    ))
                    db.commit()
                    msg = f"🔴 **{node.name}** is OFFLINE\nLast seen: {node.last_seen}"
                    await notify_discord(notification_config, msg)
                    await notify_telegram(notification_config, msg)
        except Exception as e:
            logger.error(f"Monitor loop error: {e}")
        finally:
            db.close()


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    task = asyncio.create_task(monitor_loop())
    yield
    task.cancel()


app = FastAPI(title="VPS Dashboard", lifespan=lifespan)


@app.post("/api/metrics")
async def receive_metrics(
    payload: MetricsPayload,
    db=Depends(get_db),
    _=Depends(verify_api_key),
):
    now = datetime.now(timezone.utc)
    node = db.query(Node).filter(Node.name == payload.node_name).first()

    if not node:
        node = Node(name=payload.node_name, is_online=True, first_seen=now)
        db.add(node)
        db.flush()

    was_online = node.is_online

    # Container change detection
    if node.last_containers:
        prev = {c["name"]: c for c in json.loads(node.last_containers)}
        curr = {c["name"]: c for c in payload.containers}
        for name, c in curr.items():
            if name in prev and prev[name]["status"] != c["status"] and c["status"] != "running":
                db.add(Alert(
                    node_id=node.id, node_name=node.name,
                    alert_type="container_stopped",
                    message=f"Container '{name}' on '{node.name}': {prev[name]['status']} → {c['status']}",
                ))
                msg = f"⚠️ **{node.name}**: Container `{name}` is now **{c['status']}**"
                await notify_discord(notification_config, msg)
                await notify_telegram(notification_config, msg)

    # Resource threshold alerts
    for metric_type, value, threshold, label in [
        ("high_cpu", payload.cpu_percent, ALERT_CPU_THRESHOLD, "CPU"),
        ("high_ram", payload.ram_percent, ALERT_RAM_THRESHOLD, "RAM"),
        ("high_disk", payload.disk_percent, ALERT_DISK_THRESHOLD, "Disk"),
    ]:
        existing = db.query(Alert).filter(
            Alert.node_id == node.id,
            Alert.alert_type == metric_type,
            Alert.resolved == False,
        ).first()
        if value >= threshold and not existing:
            db.add(Alert(
                node_id=node.id, node_name=node.name,
                alert_type=metric_type,
                message=f"High {label} on '{node.name}': {value:.1f}%",
            ))
            await notify_discord(notification_config, f"⚠️ **{node.name}**: High {label} **{value:.1f}%**")
            await notify_telegram(notification_config, f"⚠️ **{node.name}**: High {label} **{value:.1f}%**")
        elif value < threshold and existing:
            existing.resolved = True

    node.last_seen = now
    node.is_online = True
    node.last_cpu = payload.cpu_percent
    node.last_ram = payload.ram_percent
    node.last_disk = payload.disk_percent
    node.last_containers = json.dumps(payload.containers)
    node.uptime_seconds = payload.uptime_seconds

    db.add(Metric(
        node_id=node.id, node_name=payload.node_name, timestamp=now,
        cpu_percent=payload.cpu_percent, ram_percent=payload.ram_percent,
        ram_used_mb=payload.ram_used_mb, ram_total_mb=payload.ram_total_mb,
        disk_percent=payload.disk_percent, disk_used_gb=payload.disk_used_gb,
        disk_total_gb=payload.disk_total_gb, network_rx_mb=payload.network_rx_mb,
        network_tx_mb=payload.network_tx_mb, uptime_seconds=payload.uptime_seconds,
        containers_json=json.dumps(payload.containers),
    ))
    db.commit()

    if not was_online:
        db.add(Alert(
            node_id=node.id, node_name=node.name,
            alert_type="node_online",
            message=f"Node '{node.name}' is back online",
            resolved=True,
        ))
        db.commit()
        msg = f"🟢 **{node.name}** is back ONLINE"
        await notify_discord(notification_config, msg)
        await notify_telegram(notification_config, msg)

    return {"status": "ok"}


@app.get("/api/nodes")
async def get_nodes(db=Depends(get_db)):
    nodes = db.query(Node).all()
    return [
        {
            "id": n.id,
            "name": n.name,
            "is_online": n.is_online,
            "last_seen": n.last_seen.isoformat() if n.last_seen else None,
            "first_seen": n.first_seen.isoformat() if n.first_seen else None,
            "cpu_percent": n.last_cpu,
            "ram_percent": n.last_ram,
            "disk_percent": n.last_disk,
            "uptime_seconds": n.uptime_seconds,
            "containers": json.loads(n.last_containers) if n.last_containers else [],
        }
        for n in nodes
    ]


@app.get("/api/nodes/{node_name}/history")
async def get_node_history(node_name: str, hours: int = 6, db=Depends(get_db)):
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    metrics = (
        db.query(Metric)
        .filter(Metric.node_name == node_name, Metric.timestamp >= since)
        .order_by(Metric.timestamp.asc())
        .all()
    )
    return [
        {
            "timestamp": m.timestamp.isoformat(),
            "cpu_percent": m.cpu_percent,
            "ram_percent": m.ram_percent,
            "disk_percent": m.disk_percent,
        }
        for m in metrics
    ]


@app.get("/api/alerts")
async def get_alerts(limit: int = 100, db=Depends(get_db)):
    alerts = db.query(Alert).order_by(Alert.timestamp.desc()).limit(limit).all()
    return [
        {
            "id": a.id,
            "node_name": a.node_name,
            "alert_type": a.alert_type,
            "message": a.message,
            "timestamp": a.timestamp.isoformat(),
            "resolved": a.resolved,
        }
        for a in alerts
    ]


@app.delete("/api/nodes/{node_name}")
async def delete_node(node_name: str, db=Depends(get_db), _=Depends(verify_api_key)):
    node = db.query(Node).filter(Node.name == node_name).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    db.delete(node)
    db.commit()
    return {"status": "deleted"}


app.mount("/", StaticFiles(directory="static", html=True), name="static")
