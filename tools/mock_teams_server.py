#!/usr/bin/env python3
"""Local mock of the Microsoft Teams third-party app WebSocket API.

This is a development tool.  It implements the same handshake, pairing, state
broadcast and command shapes as the real protocol so the UI can be exercised
without Teams.  It is not a replacement for Microsoft's retired API.

Interactive commands (when run in a terminal):
  join | leave | toggle | mute | unmute | pair | unpair | status | quit
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
import uuid
from typing import Any, Dict, Optional, Set
from urllib.parse import parse_qs, urlparse

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

LOG = logging.getLogger("mock_teams")


class MockTeams:
    def __init__(self, pairing_delay: float = 0.0) -> None:
        self.pairing_delay = max(0.0, pairing_delay)
        self.in_meeting = False
        self.muted = False
        self.paired = False
        self.token: Optional[str] = None
        self.clients: Set[ServerConnection] = set()
        self.stop_event = asyncio.Event()

    # ------------------------------------------------------------- protocol
    def meeting_payload(self) -> Dict[str, Any]:
        permissions = {
            "canToggleMute": bool(self.paired and self.in_meeting),
            "canToggleVideo": bool(self.paired and self.in_meeting),
            "canToggleHand": bool(self.paired and self.in_meeting),
            "canToggleBlur": False,
            "canLeave": bool(self.paired and self.in_meeting),
            "canReact": bool(self.paired and self.in_meeting),
            "canToggleShareTray": bool(self.paired and self.in_meeting),
            "canToggleChat": bool(self.paired and self.in_meeting),
            "canStopSharing": False,
            "canPair": bool(self.in_meeting and not self.paired),
        }
        state = {
            "isMuted": bool(self.muted) if self.in_meeting else False,
            "isVideoOn": False,
            "isHandRaised": False,
            "isInMeeting": self.in_meeting,
            "isRecordingOn": False,
            "isBackgroundBlurred": False,
            "isSharing": False,
            "hasUnreadMessages": False,
        }
        return {
            "meetingUpdate": {
                "meetingState": state,
                "meetingPermissions": permissions,
            }
        }

    async def send_state(self, ws: ServerConnection) -> None:
        try:
            await ws.send(json.dumps(self.meeting_payload()))
        except ConnectionClosed:
            pass

    async def broadcast(self) -> None:
        if not self.clients:
            return
        payload = json.dumps(self.meeting_payload())
        dead = []
        for ws in list(self.clients):
            try:
                await ws.send(payload)
            except ConnectionClosed:
                dead.append(ws)
        for ws in dead:
            self.clients.discard(ws)

    async def pair(self, ws: ServerConnection) -> None:
        if self.pairing_delay:
            LOG.info("Delaying pairing approval for %.1fs", self.pairing_delay)
            await asyncio.sleep(self.pairing_delay)
        self.paired = True
        self.token = str(uuid.uuid4())
        LOG.info("Pairing approved; new token issued")
        try:
            await ws.send(json.dumps({"tokenRefresh": self.token}))
        except ConnectionClosed:
            return
        await self.broadcast()

    async def handle(self, ws: ServerConnection) -> None:
        parsed = urlparse(ws.request.path)
        query = parse_qs(parsed.query)
        token = (query.get("token") or [None])[0]
        protocol = (query.get("protocol-version") or ["?"])[0]
        app = (query.get("app") or ["?"])[0]
        LOG.info(
            "Client connected: app=%r protocol-version=%s token=%s",
            app,
            protocol,
            "supplied" if token else "none",
        )
        if token and self.token and token == self.token:
            self.paired = True
        self.clients.add(ws)
        await self.send_state(ws)
        try:
            async for raw in ws:
                if isinstance(raw, bytes):
                    raw = raw.decode("utf-8", "replace")
                try:
                    message = json.loads(raw)
                except ValueError:
                    LOG.warning("Ignoring non-JSON client frame")
                    continue
                await self.handle_command(ws, message)
        except ConnectionClosed:
            pass
        finally:
            self.clients.discard(ws)
            LOG.info("Client disconnected")

    async def handle_command(
        self, ws: ServerConnection, message: Dict[str, Any]
    ) -> None:
        action = message.get("action")
        request_id = message.get("requestId", 0)
        parameters = message.get("parameters") or {}
        LOG.info("Action: %s requestId=%s", action, request_id)

        if action == "query-state":
            await self.send_state(ws)
            await self.respond(ws, request_id, "Success")
            return

        if action == "send-reaction":
            if not self.in_meeting:
                await self.respond_error(ws, request_id, "no active call")
                return
            if not self.paired:
                await self.pair(ws)
            await self.respond(ws, request_id, "Success")
            return

        if action == "toggle-mute":
            if not self.in_meeting:
                await self.respond_error(ws, request_id, "no active call")
                return
            if not self.paired:
                await self.respond_error(
                    ws, request_id, "Pairing response resulted in no action"
                )
                return
            self.muted = not self.muted
            LOG.info("Microphone is now %s", "muted" if self.muted else "unmuted")
            await self.broadcast()
            await self.respond(ws, request_id, "Success")
            return

        await self.respond_error(ws, request_id, "unsupported action %r" % action)

    async def respond(
        self, ws: ServerConnection, request_id: Any, text: str
    ) -> None:
        try:
            await ws.send(json.dumps({"requestId": request_id, "response": text}))
        except ConnectionClosed:
            pass

    async def respond_error(
        self, ws: ServerConnection, request_id: Any, text: str
    ) -> None:
        try:
            await ws.send(json.dumps({"requestId": request_id, "errorMsg": text}))
        except ConnectionClosed:
            pass

    # ---------------------------------------------------------- demo control
    async def apply_command(self, command: str) -> bool:
        command = command.strip().lower()
        if command == "join":
            self.in_meeting = True
            self.muted = False
        elif command == "leave":
            self.in_meeting = False
            self.muted = False
        elif command == "toggle":
            if self.in_meeting:
                self.muted = not self.muted
        elif command == "mute":
            if self.in_meeting:
                self.muted = True
        elif command == "unmute":
            if self.in_meeting:
                self.muted = False
        elif command == "pair":
            if self.clients:
                await self.pair(next(iter(self.clients)))
        elif command == "unpair":
            self.paired = False
            self.token = None
        elif command == "status":
            print(
                "state: %s, mic: %s, paired: %s, clients: %d"
                % (
                    "in call" if self.in_meeting else "idle",
                    "muted" if self.muted else "unmuted",
                    self.paired,
                    len(self.clients),
                ),
                file=sys.stderr,
            )
            return True
        elif command in ("quit", "exit"):
            self.stop_event.set()
            return False
        else:
            print(
                "Commands: join, leave, toggle, mute, unmute, pair, unpair, "
                "status, quit",
                file=sys.stderr,
            )
            return True
        await self.broadcast()
        print("mock state: %s / %s" % (
            "in call" if self.in_meeting else "idle",
            "muted" if self.muted else "unmuted",
        ), file=sys.stderr)
        return True

    async def console_loop(self) -> None:
        loop = asyncio.get_running_loop()
        while not self.stop_event.is_set():
            try:
                command = await loop.run_in_executor(None, input, "mock> ")
            except (EOFError, KeyboardInterrupt):
                break
            if not await self.apply_command(command):
                break

    async def auto_demo(self) -> None:
        """A deterministic loop for screenshots and casual UI testing."""

        try:
            while not self.stop_event.is_set():
                await asyncio.sleep(3.0)
                self.in_meeting = True
                self.muted = False
                await self.broadcast()
                await asyncio.sleep(4.0)
                self.muted = True
                await self.broadcast()
                await asyncio.sleep(4.0)
                self.muted = False
                await self.broadcast()
                await asyncio.sleep(4.0)
                self.in_meeting = False
                self.muted = False
                await self.broadcast()
        except asyncio.CancelledError:
            raise


async def run_server(args: argparse.Namespace) -> None:
    mock = MockTeams(pairing_delay=args.pairing_delay)
    if args.state == "in-call":
        mock.in_meeting = True
        mock.muted = False
    elif args.state == "muted":
        mock.in_meeting = True
        mock.muted = True

    async with serve(mock.handle, args.host, args.port, ping_interval=20) as server:
        sockets = server.sockets or []
        address = sockets[0].getsockname() if sockets else (args.host, args.port)
        LOG.info("Mock Teams API listening on ws://%s:%s", address[0], address[1])
        LOG.info("Use the floating app's normal settings; no real Teams needed")
        tasks = []
        if args.auto_demo:
            tasks.append(asyncio.create_task(mock.auto_demo()))
        if sys.stdin.isatty() and not args.no_console:
            tasks.append(asyncio.create_task(mock.console_loop()))
            print(
                "Commands: join, leave, toggle, mute, unmute, pair, unpair, "
                "status, quit",
                file=sys.stderr,
            )
        try:
            await mock.stop_event.wait()
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8124)
    parser.add_argument(
        "--state",
        choices=("idle", "in-call", "muted"),
        default="idle",
        help="Initial mock meeting state",
    )
    parser.add_argument(
        "--auto-demo",
        action="store_true",
        help="Cycle idle → unmuted call → muted call every few seconds",
    )
    parser.add_argument(
        "--no-console",
        action="store_true",
        help="Disable interactive stdin commands",
    )
    parser.add_argument(
        "--pairing-delay",
        type=float,
        default=0.0,
        metavar="SECONDS",
        help="Wait before approving a pairing request (for UI demos)",
    )
    parser.add_argument("--debug", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    try:
        asyncio.run(run_server(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
