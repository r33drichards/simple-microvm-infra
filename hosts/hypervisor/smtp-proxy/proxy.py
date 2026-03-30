#!/usr/bin/env python3
"""
SMTP-to-SES relay proxy.

Accepts SMTP connections from MicroVMs on the hypervisor's bridge gateway IPs
and forwards emails via AWS SES API (send_raw_email).

Required env vars:
  AWS_ACCESS_KEY_ID       AWS access key for SES
  AWS_SECRET_ACCESS_KEY   AWS secret key for SES
  AWS_REGION              AWS region for SES (e.g. us-west-2)

Optional:
  SMTP_LISTEN_PORT        Port to listen on (default: 2525)
  SMTP_LISTEN_ADDRS       Comma-separated listen addresses (default: 0.0.0.0)
  ALLOWED_FROM_DOMAINS    Comma-separated allowed sender domains (empty = allow all)
  ALLOWED_TO_DOMAINS      Comma-separated allowed recipient domains (empty = allow all)
  MAX_MESSAGE_SIZE        Max message size in bytes (default: 10485760 = 10MB)
"""
import asyncio
import email
import json
import logging
import os
import sys

import boto3
from aiosmtpd.controller import Controller
from aiosmtpd.smtp import SMTP as SMTPServer, Envelope, Session

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

AWS_REGION = os.environ.get("AWS_REGION", "us-west-2")
LISTEN_PORT = int(os.environ.get("SMTP_LISTEN_PORT", "2525"))
LISTEN_ADDRS = os.environ.get("SMTP_LISTEN_ADDRS", "0.0.0.0").split(",")
ALLOWED_FROM_DOMAINS = [
    d.strip() for d in os.environ.get("ALLOWED_FROM_DOMAINS", "").split(",") if d.strip()
]
ALLOWED_TO_DOMAINS = [
    d.strip() for d in os.environ.get("ALLOWED_TO_DOMAINS", "").split(",") if d.strip()
]
MAX_MESSAGE_SIZE = int(os.environ.get("MAX_MESSAGE_SIZE", "10485760"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [smtp-proxy] %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("smtp-proxy")

# ---------------------------------------------------------------------------
# SES client (initialized lazily)
# ---------------------------------------------------------------------------

_ses_client = None


def get_ses_client():
    global _ses_client
    if _ses_client is None:
        _ses_client = boto3.client("ses", region_name=AWS_REGION)
    return _ses_client


# ---------------------------------------------------------------------------
# Domain validation
# ---------------------------------------------------------------------------

def _extract_domain(addr: str) -> str:
    """Extract domain from email address."""
    if "@" in addr:
        return addr.rsplit("@", 1)[1].lower()
    return addr.lower()


def _check_domain(addr: str, allowed: list[str], direction: str) -> str | None:
    """Return error message if domain not allowed, None if OK."""
    if not allowed:
        return None
    domain = _extract_domain(addr)
    if domain not in allowed:
        return f"550 {direction} domain {domain} not allowed"
    return None


# ---------------------------------------------------------------------------
# SMTP handler
# ---------------------------------------------------------------------------

class SESRelayHandler:
    """SMTP handler that relays messages through AWS SES."""

    async def handle_MAIL(self, server, session: Session, envelope: Envelope, address, mail_options):
        err = _check_domain(address, ALLOWED_FROM_DOMAINS, "Sender")
        if err:
            log.warning("Rejected sender %s: domain not in allowlist", address)
            return err
        envelope.mail_from = address
        return "250 OK"

    async def handle_RCPT(self, server, session: Session, envelope: Envelope, address, rcpt_options):
        err = _check_domain(address, ALLOWED_TO_DOMAINS, "Recipient")
        if err:
            log.warning("Rejected recipient %s: domain not in allowlist", address)
            return err
        envelope.rcpt_tos.append(address)
        return "250 OK"

    async def handle_DATA(self, server, session: Session, envelope: Envelope):
        mail_from = envelope.mail_from
        rcpt_tos = envelope.rcpt_tos
        raw_data = envelope.content

        if isinstance(raw_data, str):
            raw_data = raw_data.encode("utf-8")

        if len(raw_data) > MAX_MESSAGE_SIZE:
            log.warning("Message too large (%d bytes) from %s", len(raw_data), mail_from)
            return "552 Message too large"

        log.info("Relaying message from=%s to=%s size=%d", mail_from, rcpt_tos, len(raw_data))

        try:
            ses = get_ses_client()
            response = ses.send_raw_email(
                Source=mail_from,
                Destinations=rcpt_tos,
                RawMessage={"Data": raw_data},
            )
            message_id = response.get("MessageId", "unknown")
            log.info("SES accepted message_id=%s from=%s to=%s", message_id, mail_from, rcpt_tos)
            return f"250 OK Message accepted (SES ID: {message_id})"

        except ses.exceptions.MessageRejected as e:
            log.error("SES rejected message: %s", e)
            return "550 Message rejected by SES"
        except ses.exceptions.MailFromDomainNotVerifiedException as e:
            log.error("SES domain not verified: %s", e)
            return "550 Sender domain not verified in SES"
        except Exception as e:
            log.error("SES send failed: %s", e)
            return "451 Temporary failure, please retry"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def run():
    handler = SESRelayHandler()
    controllers = []

    for addr in LISTEN_ADDRS:
        addr = addr.strip()
        log.info("Starting SMTP proxy on %s:%d", addr, LISTEN_PORT)
        controller = Controller(
            handler,
            hostname=addr,
            port=LISTEN_PORT,
            server_hostname="smtp-proxy.local",
            data_size_limit=MAX_MESSAGE_SIZE,
        )
        controller.start()
        controllers.append(controller)

    log.info("SMTP-to-SES proxy ready (region=%s)", AWS_REGION)

    # Keep running
    try:
        while True:
            await asyncio.sleep(3600)
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        for c in controllers:
            c.stop()


if __name__ == "__main__":
    asyncio.run(run())
