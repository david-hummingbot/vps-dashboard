import httpx
import logging
from dataclasses import dataclass
from typing import Optional

logger = logging.getLogger(__name__)


@dataclass
class NotificationConfig:
    discord_webhook: Optional[str] = None
    telegram_bot_token: Optional[str] = None
    telegram_chat_id: Optional[str] = None


async def notify_discord(config: NotificationConfig, message: str):
    if not config.discord_webhook:
        return
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            payload = {"content": message, "username": "VPS Monitor"}
            resp = await client.post(config.discord_webhook, json=payload)
            resp.raise_for_status()
    except Exception as e:
        logger.error(f"Discord notification failed: {e}")


async def notify_telegram(config: NotificationConfig, message: str):
    if not config.telegram_bot_token or not config.telegram_chat_id:
        return
    try:
        url = f"https://api.telegram.org/bot{config.telegram_bot_token}/sendMessage"
        # Strip Discord markdown bold (**text**) → Telegram bold (*text*)
        tg_message = message.replace("**", "*")
        async with httpx.AsyncClient(timeout=10) as client:
            payload = {
                "chat_id": config.telegram_chat_id,
                "text": tg_message,
                "parse_mode": "Markdown",
            }
            resp = await client.post(url, json=payload)
            resp.raise_for_status()
    except Exception as e:
        logger.error(f"Telegram notification failed: {e}")
