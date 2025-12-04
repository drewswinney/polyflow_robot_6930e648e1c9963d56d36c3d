# robot/webrtc.py
import asyncio
import json
import subprocess
import time
import threading
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import socketio
from aiortc import (
    RTCPeerConnection,
    RTCSessionDescription,
    RTCConfiguration,
    RTCIceServer,
)
from aiortc.rtcdatachannel import RTCDataChannel

import rclpy
from rclpy.node import Node
from rclpy.executors import SingleThreadedExecutor
from std_msgs.msg import Float32


class WebRTCBridge(Node):
    def __init__(self):
        super().__init__("webrtc_client")
        self.get_logger().set_level(rclpy.logging.LoggingSeverity.DEBUG)

        # Declare ROS params with defaults
        self.declare_parameter("robot_id", "robot-001")
        self.declare_parameter("signaling_url", "ws://polyflow.studio/signal")
        self.declare_parameter("auth_token", "")
        self.declare_parameter("socketio_namespace", "")
        self.declare_parameter("socketio_path", "")
        self.declare_parameter("ice_servers", "stun:stun.l.google.com:19302")
        self.declare_parameter("ice_username", "")
        self.declare_parameter("ice_password", "")

        self.robot_id = self.get_parameter("robot_id").get_parameter_value().string_value
        self.signaling_url = self.get_parameter("signaling_url").get_parameter_value().string_value
        self.auth_token = self.get_parameter("auth_token").get_parameter_value().string_value
        self.socketio_namespace = self.get_parameter("socketio_namespace").get_parameter_value().string_value
        self.socketio_path = self.get_parameter("socketio_path").get_parameter_value().string_value
        self.ice_servers = self.get_parameter("ice_servers").value
        self.ice_username = self.get_parameter("ice_username").get_parameter_value().string_value
        self.ice_password = self.get_parameter("ice_password").get_parameter_value().string_value

        self.get_logger().info(f"WebRTC client starting for robot_id={self.robot_id}, signaling={self.signaling_url}")

        # ROS pubs/subs
        self.j1_cmd_pub = self.create_publisher(Float32, "/arm/j1/cmd/position", 10)
        self.j1_state_sub = self.create_subscription(
            Float32, "/arm/j1/state/position", self._on_j1_state, 10
        )

        # Holds outbound state channel
        self.state_channel: RTCDataChannel | None = None

        self.rebuild_service_name = "polyflow-nixos-rebuild.service"
        self._rebuild_lock = threading.Lock()

    # === ROS Callbacks ===
    def _on_j1_state(self, msg: Float32):
        """When robot publishes state, send it over WebRTC state channel."""
        if self.state_channel and self.state_channel.readyState == "open":
            env = {
                "topic": "robot/arm/j1/state/position",
                "qos": "state",
                "tUnixNanos": int(time.time() * 1e9),
                "payload": {"positionRad": float(msg.data)},
            }
            try:
                self.state_channel.send(json.dumps(env))
            except Exception as e:
                self.get_logger().warn(f"Failed to send state: {e}")

    # === Control handler ===
    def on_control_message(self, data: str):
        try:
            env = json.loads(data)
        except Exception:
            return
        topic = env.get("topic", "")
        if topic == "robot/arm/j1/cmd/position":
            pos = float(env["payload"]["positionRad"])
            msg = Float32()
            msg.data = pos
            self.j1_cmd_pub.publish(msg)
            self.get_logger().info(f"Received control: j1 position={pos}")
        elif topic == "system/nixos/rebuild":
            threading.Thread(
                target=self.trigger_nixos_rebuild, daemon=True
            ).start()

    def trigger_nixos_rebuild(self):
        service_name = self.rebuild_service_name or "polyflow-nixos-rebuild.service"
        cmd = ["systemctl", "start", "--no-block", service_name]
        with self._rebuild_lock:
            try:
                subprocess.run(cmd, check=True)
                self.get_logger().info(f"Triggered nixos-rebuild service {service_name}")
            except subprocess.CalledProcessError as exc:
                self.get_logger().error(f"Failed to start {service_name}: {exc}")


async def run_webrtc(node: WebRTCBridge):
    """Main async WebRTC loop using Socket.IO for signaling."""

    raw_ice_servers = node.ice_servers
    if isinstance(raw_ice_servers, str):
        try:
            parsed_servers = json.loads(raw_ice_servers)
            if isinstance(parsed_servers, str):
                parsed_servers = [parsed_servers]
            elif isinstance(parsed_servers, (list, tuple)):
                parsed_servers = [str(s) for s in parsed_servers if str(s).strip()]
            else:
                parsed_servers = [str(parsed_servers)]
        except json.JSONDecodeError:
            cleaned = raw_ice_servers.strip()
            if cleaned.startswith("[") and cleaned.endswith("]"):
                cleaned = cleaned[1:-1]
            parsed_servers = [
                s.strip().strip(" '\"")
                for s in cleaned.split(",")
                if s.strip().strip(" '\"")
            ]
    elif isinstance(raw_ice_servers, (list, tuple)):
        parsed_servers = [str(s) for s in raw_ice_servers if str(s).strip()]
    else:
        parsed_servers = []

    ice_servers = []
    for entry in parsed_servers:
        entry = entry.strip()
        if not entry:
            continue
        ice_servers.append(
            RTCIceServer(
                urls=[entry],
                username=node.ice_username or None,
                credential=node.ice_password or None,
            )
        )

    rtc_config = RTCConfiguration(iceServers=ice_servers) if ice_servers else None

    if ice_servers:
        node.get_logger().debug(f"Using ICE servers: {parsed_servers} (username set: {bool(node.ice_username)})")
    else:
        node.get_logger().debug("No ICE servers configured; relying on host candidates only.")

    parsed = urlparse(node.signaling_url)
    scheme_map = {"ws": "http", "wss": "https"}
    scheme = scheme_map.get(parsed.scheme, parsed.scheme or "http")
    if not parsed.netloc:
        raise ValueError("signaling_url must include a host (e.g. ws://host:port/path)")

    base_url = urlunparse((scheme, parsed.netloc, "", "", "", ""))

    namespace_config = node.socketio_namespace.strip()
    if namespace_config:
        namespace = namespace_config if namespace_config.startswith("/") else f"/{namespace_config}"
    else:
        namespace = "/"

    raw_path = parsed.path or ""

    path_config = node.socketio_path.strip()
    if path_config:
        socketio_path = path_config.lstrip("/")
    elif raw_path and raw_path != "/":
        socketio_path = raw_path.lstrip("/")
    else:
        socketio_path = "socket.io"

    query_pairs = list(parse_qsl(parsed.query, keep_blank_values=True))
    if node.auth_token and not any(key == "token" for key, _ in query_pairs):
        query_pairs.append(("token", node.auth_token))
    connect_query = urlencode(query_pairs)
    connect_url = base_url if not connect_query else f"{base_url}?{connect_query}"

    sio = socketio.AsyncClient(reconnection=True)
    pending_messages: list[dict] = []

    async def _emit_now(payload: dict):
        node.get_logger().debug(f"Emitting signaling message: {payload.get('type', '<unknown>')} -> {payload}")
        await sio.emit("message", payload, namespace=namespace)

    async def emit_message(payload: dict):
        if not sio.connected:
            node.get_logger().debug(f"Queueing signaling message (offline): {payload.get('type', '<unknown>')} -> {payload}")
            pending_messages.append(payload)
            return
        try:
            await _emit_now(payload)
        except Exception as exc:
            node.get_logger().error(
                f"Failed to emit signaling message '{payload.get('type', '<unknown>')}': {exc}"
            )

    async def flush_pending():
        if not pending_messages or not sio.connected:
            return
        while pending_messages:
            message = pending_messages.pop(0)
            try:
                await _emit_now(message)
            except Exception as exc:
                node.get_logger().error(
                    f"Failed to flush signaling message '{message.get('type', '<unknown>')}': {exc}"
                )
                pending_messages.insert(0, message)
                break

    pc_holder: dict[str, RTCPeerConnection | None] = {"pc": None}

    async def reset_peer_connection(pc: RTCPeerConnection | None, reason: str):
        if pc is None or pc != pc_holder.get("pc"):
            return

        node.get_logger().info(f"Resetting peer connection ({reason}); awaiting new offers")
        node.state_channel = None

        try:
            if pc.connectionState != "closed":
                await pc.close()
        except Exception as exc:
            node.get_logger().warn(f"Error while closing peer connection: {exc}")

        build_peer_connection()

    def build_peer_connection():
        new_pc = RTCPeerConnection(configuration=rtc_config)
        pc_holder["pc"] = new_pc
        node.state_channel = None

        @new_pc.on("datachannel")
        def on_datachannel(channel: RTCDataChannel):
            node.get_logger().info(f"DataChannel opened: {channel.label}")

            @channel.on("close")
            def on_channel_close():
                node.get_logger().info(f"DataChannel closed: {channel.label}")
                if node.state_channel is channel:
                    node.state_channel = None

            if channel.label == "control":
                @channel.on("message")
                def on_message(message):
                    if isinstance(message, bytes):
                        message = message.decode("utf-8", "ignore")
                    node.on_control_message(message)
            elif channel.label == "state":
                node.state_channel = channel

        @new_pc.on("icecandidate")
        def on_icecandidate(candidate):
            node.get_logger().debug(f"ICE candidate event: {candidate}")

            async def _send():
                if candidate is None:
                    payload = {
                        "type": "candidate",
                        "robotId": node.robot_id,
                        "candidate": None,
                    }
                else:
                    payload = {
                        "type": "candidate",
                        "robotId": node.robot_id,
                        "candidate": {
                            "candidate": candidate.to_sdp(),
                            "sdpMid": candidate.sdpMid,
                            "sdpMLineIndex": candidate.sdpMLineIndex,
                        },
                    }
                await emit_message(payload)
                node.get_logger().debug(
                    f"Sent signaling candidate message: {payload['candidate']}"
                    if payload["candidate"] is not None
                    else "Sent signaling candidate end-of-candidates marker"
                )

            asyncio.ensure_future(_send())

        @new_pc.on("connectionstatechange")
        async def on_connectionstatechange():
            state = new_pc.connectionState
            node.get_logger().info(f"Peer connection state changed: {state}")
            if state in ("failed", "closed"):
                await reset_peer_connection(new_pc, f"connection state {state}")

        @new_pc.on("iceconnectionstatechange")
        async def on_iceconnectionstatechange():
            state = new_pc.iceConnectionState
            node.get_logger().info(f"ICE connection state changed: {state}")
            if state in ("failed", "closed"):
                await reset_peer_connection(new_pc, f"ICE state {state}")

        return new_pc

    build_peer_connection()

    @sio.event
    async def connect():
        node.get_logger().info("Connected to signaling server")
        hello = {"type": "hello", "role": "robot", "robotId": node.robot_id}
        if node.auth_token:
            hello["token"] = node.auth_token
        try:
            await _emit_now(hello)
        except Exception as exc:
            node.get_logger().error(f"Failed to emit hello during connect: {exc}")
            pending_messages.insert(0, hello)
        await flush_pending()

    @sio.event
    async def connect_error(data):
        node.get_logger().error(f"Socket.IO connection failed: {data}")

    @sio.event
    async def disconnect():
        node.get_logger().warn("Disconnected from signaling server")
        await reset_peer_connection(pc_holder.get("pc"), "Socket.IO disconnect")

    @sio.on("message", namespace=namespace)
    async def on_message(data):
        node.get_logger().debug(f"Received signaling payload: {data}")
        if isinstance(data, str):
            try:
                data = json.loads(data)
            except json.JSONDecodeError:
                node.get_logger().warn("Ignoring non-JSON signaling payload")
                return
        if not isinstance(data, dict):
            node.get_logger().warn("Ignoring unexpected signaling payload type!")
            return

        pc = pc_holder.get("pc")
        if pc is None:
            node.get_logger().info("Peer connection missing; rebuilding before handling signaling message")
            build_peer_connection()
            pc = pc_holder.get("pc")
        if pc is None:
            node.get_logger().error("Failed to (re)create peer connection; dropping signaling message")
            return

        msg_type = data.get("type")
        if msg_type == "offer":
            signaling_state = pc.signalingState
            if signaling_state not in ("stable", "have-remote-offer"):
                node.get_logger().info(
                    f"Peer connection in state '{signaling_state}' before new offer; resetting"
                )
                await reset_peer_connection(pc, f"signaling state {signaling_state}")
                pc = pc_holder.get("pc")
                if pc is None:
                    node.get_logger().error("Peer connection unavailable after reset; cannot handle offer")
                    return
            try:
                await pc.setRemoteDescription(
                    RTCSessionDescription(sdp=data["sdp"], type="offer")
                )
            except Exception as exc:
                node.get_logger().error(f"Failed to set remote description: {exc}")
                return

            try:
                answer = await pc.createAnswer()
                await pc.setLocalDescription(answer)
            except Exception as exc:
                node.get_logger().error(f"Failed to create local answer: {exc}")
                return

            response = {
                "type": "answer",
                "robotId": node.robot_id,
                "sdp": pc.localDescription.sdp,
                "to": data.get("from"),
            }
            await emit_message(response)

        elif msg_type == "candidate":
            if pc is None:
                node.get_logger().warn("No active peer connection to receive ICE candidate; ignoring")
                return
            candidate_payload = data.get("candidate")
            if candidate_payload in (None, "null"):
                node.get_logger().debug("Received end-of-candidates marker from signaling")
                try:
                    await pc.addIceCandidate(None)
                    node.get_logger().debug("Signaled end-of-candidates to peer connection")
                except Exception as exc:
                    node.get_logger().warn(f"Failed to signal end-of-candidates: {exc}")
                return

            cand_mid = data.get("sdpMid")
            cand_index = data.get("sdpMLineIndex")

            if isinstance(candidate_payload, dict):
                cand_candidate = candidate_payload.get("candidate")
                cand_mid = candidate_payload.get("sdpMid", cand_mid)
                cand_index = candidate_payload.get("sdpMLineIndex", cand_index)
            elif isinstance(candidate_payload, str):
                cand_candidate = candidate_payload
            else:
                node.get_logger().warn("Ignoring ICE candidate with unexpected payload type")
                return

            if not cand_candidate:
                node.get_logger().debug("ICE candidate payload missing 'candidate' data")
                return

            class _CandidateShim:
                __slots__ = (
                    "candidate",
                    "sdpMid",
                    "sdpMLineIndex",
                    "foundation",
                    "component",
                    "priority",
                    "protocol",
                    "ip",
                    "port",
                    "type",
                    "tcpType",
                    "relatedAddress",
                    "relatedPort",
                )

                def __init__(self, candidate, mid, index):
                    self.candidate = candidate
                    self.sdpMid = mid
                    self.sdpMLineIndex = index
                    self.foundation = None
                    self.component = None
                    self.priority = None
                    self.protocol = None
                    self.ip = None
                    self.port = None
                    self.type = None
                    self.tcpType = None
                    self.relatedAddress = None
                    self.relatedPort = None
                    self._parse_candidate(candidate)

                def _parse_candidate(self, value: str):
                    try:
                        parts = value.split()
                        if not parts:
                            return
                        foundation_part = parts[0]
                        if foundation_part.startswith("candidate:"):
                            self.foundation = foundation_part.split(":", 1)[1]
                        else:
                            self.foundation = foundation_part
                        if len(parts) > 1:
                            self.component = int(parts[1])
                        if len(parts) > 2:
                            self.protocol = parts[2].lower()
                        if len(parts) > 3:
                            self.priority = int(parts[3])
                        if len(parts) > 4:
                            self.ip = parts[4]
                        if len(parts) > 5:
                            self.port = int(parts[5])
                        i = 6
                        while i < len(parts):
                            label = parts[i]
                            if label == "typ" and i + 1 < len(parts):
                                self.type = parts[i + 1]
                                i += 2
                            elif label == "tcptype" and i + 1 < len(parts):
                                self.tcpType = parts[i + 1]
                                i += 2
                            elif label == "raddr" and i + 1 < len(parts):
                                self.relatedAddress = parts[i + 1]
                                i += 2
                            elif label == "rport" and i + 1 < len(parts):
                                try:
                                    self.relatedPort = int(parts[i + 1])
                                except ValueError:
                                    self.relatedPort = None
                                i += 2
                            else:
                                i += 1
                    except Exception:
                        # Leave parsed fields as None; caller will log already.
                        pass

            try:
                await pc.addIceCandidate(_CandidateShim(cand_candidate, cand_mid, cand_index))
                node.get_logger().debug(
                    f"Added ICE candidate (mid={cand_mid}, mline={cand_index}): {cand_candidate}"
                )
            except Exception as exc:
                node.get_logger().warn(f"Failed to add ICE candidate: {exc}")

        else:
            node.get_logger().debug(f"Ignoring unsupported signaling message type: {msg_type}")

    try:
        await sio.connect(
            connect_url,
            transports=["websocket"],
            namespaces=[namespace],
            socketio_path=socketio_path,
            auth={"token": node.auth_token} if node.auth_token else None,
        )
        await sio.wait()
    finally:
        if sio.connected:
            await sio.disconnect()
        current_pc = pc_holder.get("pc")
        if current_pc is not None:
            try:
                await current_pc.close()
            except Exception as exc:
                node.get_logger().warn(f"Error while closing peer connection during shutdown: {exc}")


def main(args=None):
    rclpy.init(args=args)
    node = WebRTCBridge()

    # Spin ROS in the background so subscriptions/timers actually run
    executor = SingleThreadedExecutor()
    executor.add_node(node)
    ros_thread = threading.Thread(target=executor.spin, daemon=True)
    ros_thread.start()
    node.get_logger().info("ROS executor started (background thread)")

    # Run the async WebRTC client
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        node.get_logger().info("Attempting to run the WebRTC client…")
        loop.run_until_complete(run_webrtc(node))
    except KeyboardInterrupt:
        node.get_logger().info("Keyboard interrupt received")
    except Exception as e:
        node.get_logger().error(f"WebRTC loop crashed: {e}")
    finally:
        node.get_logger().info("Shutting down")
        executor.shutdown()
        loop.stop()
        loop.close()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
