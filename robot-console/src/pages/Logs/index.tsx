import {
  Button,
  Label,
  Variant,
  TextField,
  Checkbox,
} from "@polyflowrobotics/ui-components";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { API_BASE } from "../../config";
import "./logs.scss";

type FilterMode = "service" | "ros_node" | "custom";

type LogEntry = {
  id: string;
  timestamp: string;
  line: string;
  labels: Record<string, string>;
};

const FILTER_OPTIONS: {
  value: FilterMode;
  label: string;
  description: string;
}[] = [
  { value: "service", label: "Service", description: "systemd service" },
  { value: "ros_node", label: "ROS Node", description: "ROS 2 node" },
  { value: "custom", label: "Custom", description: "Raw Loki selector" },
];

const MAX_LOG_LINES = 500;

const buildSelector = (
  mode: FilterMode,
  target: string,
  custom: string
): string => {
  if (mode === "custom") {
    return custom.trim();
  }
  if (!target.trim()) {
    return "";
  }
  const labelKey = mode === "service" ? "service" : "ros_node";
  const value = target.trim();
  return `{${labelKey}="${value}"}`;
};

const buildLogsWebsocketUrl = (
  apiBase: string,
  selector: string,
  limit?: string,
  delayFor?: string
) => {
  const resolvedBase = new URL(apiBase, window.location.origin);
  resolvedBase.pathname = `${resolvedBase.pathname.replace(
    /\/+$/,
    ""
  )}/logs/tail`;
  resolvedBase.search = "";
  resolvedBase.searchParams.set("query", selector);
  if (limit) {
    resolvedBase.searchParams.set("limit", limit);
  }
  if (delayFor) {
    resolvedBase.searchParams.set("delay_for", delayFor);
  }
  resolvedBase.protocol = resolvedBase.protocol === "https:" ? "wss:" : "ws:";
  return resolvedBase.toString();
};

const formatTimestamp = (value: string) => {
  const millis = Number(value) / 1_000_000;
  if (!Number.isFinite(millis)) return value;
  const date = new Date(millis);
  return `${date.toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  })}.${String(date.getMilliseconds()).padStart(3, "0")}`;
};

const formatLabels = (labels: Record<string, string>) => {
  const entries = Object.entries(labels);
  if (!entries.length) return "";
  return entries.map(([key, value]) => `${key}=${value}`).join(" ");
};

export const LogPage = () => {
  const apiBase = useMemo(() => API_BASE, []);
  const [mode, setMode] = useState<FilterMode>("service");
  const [target, setTarget] = useState("");
  const [customSelector, setCustomSelector] = useState('{service="polyflow"}');
  const [limit, setLimit] = useState("200");
  const [delayFor, setDelayFor] = useState("");
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [status, setStatus] = useState<
    "idle" | "connecting" | "streaming" | "error"
  >("idle");
  const [statusMessage, setStatusMessage] = useState("");
  const [autoScroll, setAutoScroll] = useState(true);
  const logContainerRef = useRef<HTMLDivElement | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

  const selector = useMemo(
    () => buildSelector(mode, target, customSelector),
    [mode, target, customSelector]
  );

  const disconnect = useCallback(() => {
    if (wsRef.current) {
      wsRef.current.close();
      wsRef.current = null;
    }
  }, []);

  useEffect(() => {
    return () => disconnect();
  }, [disconnect]);

  useEffect(() => {
    if (!autoScroll) return;
    const container = logContainerRef.current;
    if (container) {
      container.scrollTop = container.scrollHeight;
    }
  }, [logs, autoScroll]);

  const sanitizedLimit = useMemo(() => {
    const trimmed = limit.trim();
    if (!trimmed) return "";
    const parsed = Number(trimmed);
    if (!Number.isFinite(parsed) || parsed <= 0) return "";
    return Math.floor(parsed).toString();
  }, [limit]);

  const handleMessage = useCallback(
    (event: MessageEvent) => {
      if (typeof event.data !== "string") {
        return;
      }
      let payload: any;
      try {
        payload = JSON.parse(event.data);
      } catch (err) {
        return;
      }
      if (payload?.type === "error") {
        setStatus("error");
        setStatusMessage(payload.message || "Log provider reported an error");
        disconnect();
        return;
      }
      const streams = payload?.streams;
      if (!Array.isArray(streams)) {
        return;
      }
      const freshEntries: LogEntry[] = [];
      for (const stream of streams) {
        const values: Array<[string, string]> = stream?.values ?? [];
        const streamLabels: Record<string, string> = stream?.stream ?? {};
        for (const [timestamp, line] of values) {
          freshEntries.push({
            id: `${timestamp}-${line}`,
            timestamp,
            line,
            labels: streamLabels,
          });
        }
      }
      if (!freshEntries.length) {
        return;
      }
      setLogs((prev) => {
        const combined = [...prev, ...freshEntries];
        if (combined.length <= MAX_LOG_LINES) {
          return combined;
        }
        return combined.slice(combined.length - MAX_LOG_LINES);
      });
    },
    [disconnect]
  );

  const connect = useCallback(() => {
    if (!selector) {
      setStatus("error");
      setStatusMessage("Provide a query before tailing logs");
      return;
    }
    disconnect();
    setLogs([]);
    setStatus("connecting");
    setStatusMessage("");
    const url = buildLogsWebsocketUrl(
      apiBase,
      selector,
      sanitizedLimit,
      delayFor.trim() || undefined
    );
    const ws = new WebSocket(url);
    wsRef.current = ws;
    ws.onopen = () => {
      setStatus("streaming");
      setStatusMessage("Connected to Grafana Alloy");
    };
    ws.onmessage = handleMessage;
    ws.onerror = () => {
      setStatus("error");
      setStatusMessage("WebSocket connection error");
    };
    ws.onclose = (event) => {
      wsRef.current = null;
      if (event.wasClean && event.code === 1000) {
        setStatus("idle");
        setStatusMessage("Log stream closed");
      } else {
        setStatus("error");
        setStatusMessage("Log stream disconnected unexpectedly");
      }
    };
  }, [apiBase, selector, sanitizedLimit, delayFor, handleMessage, disconnect]);

  const stopStreaming = useCallback(() => {
    disconnect();
    setStatus("idle");
    setStatusMessage("Log stream stopped");
  }, [disconnect]);

  const streaming = status === "streaming";

  const renderSelectorField = () => {
    if (mode === "custom") {
      return (
        <div className="field">
          <Label>Custom selector</Label>
          <textarea
            className="custom-selector"
            value={customSelector}
            onChange={(event) => setCustomSelector(event.target.value)}
            placeholder={`{service="polyflow"}`}
          />
        </div>
      );
    }
    return (
      <div className="field">
        <Label>{mode === "service" ? "Service name" : "ROS node"}</Label>
        <TextField
          value={target}
          onChange={(value) => setTarget(value)}
          placeholder={
            mode === "service" ? "polyflow-webrtc.service" : "rtabmap"
          }
        />
      </div>
    );
  };

  return (
    <div className="body logs-page">
      <div className="log-layout">
        <div className="log-controls">
          <div className="group">
            <div className="group-header">Log source</div>
            <div className="filter-options">
              {FILTER_OPTIONS.map((option) => (
                <label key={option.value} className="option">
                  <input
                    type="radio"
                    checked={mode === option.value}
                    onChange={() => setMode(option.value)}
                  />
                  <div>
                    <div className="option-title">{option.label}</div>
                    <div className="option-description">
                      {option.description}
                    </div>
                  </div>
                </label>
              ))}
            </div>
            {renderSelectorField()}
            <div className="inline-fields">
              <div className="field">
                <Label>Result limit</Label>
                <TextField
                  type="number"
                  min={1}
                  inputMode="numeric"
                  value={limit}
                  onChange={(value) => setLimit(value)}
                />
              </div>
              <div className="field">
                <Label>Delay (optional)</Label>
                <TextField
                  value={delayFor}
                  onChange={(value) => setDelayFor(value)}
                  placeholder="1s"
                />
              </div>
            </div>
            <label className="option checkbox">
              <Checkbox
                checked={autoScroll}
                onChange={(value) => setAutoScroll(value)}
              />
              Auto-scroll to newest log
            </label>
            <div className="actions">
              <Button
                variant={Variant.Primary}
                onPress={connect}
                disabled={streaming || status === "connecting"}
              >
                {status === "connecting" ? "Connecting..." : "Start tailing"}
              </Button>
              <Button
                variant={Variant.Secondary}
                onPress={stopStreaming}
                disabled={!streaming && status !== "error"}
              >
                Stop
              </Button>
            </div>
            {statusMessage && (
              <div className={`status ${status}`}>
                <Label>Status</Label>
                <div className="value">{statusMessage}</div>
              </div>
            )}
          </div>
        </div>
        <div className="log-stream">
          <div className="log-stream-header">
            <div>
              <div className="title">Live logs</div>
              <div className="subtitle">
                {selector || "Choose a selector to begin streaming"}
              </div>
            </div>
            <div className={`status-indicator ${status}`}>
              {status === "streaming"
                ? "Streaming"
                : status === "connecting"
                ? "Connecting"
                : status === "error"
                ? "Error"
                : "Idle"}
            </div>
          </div>
          <div className="log-lines" ref={logContainerRef}>
            {logs.length === 0 ? (
              <div className="empty-state">
                No log entries yet. Start streaming to view logs.
              </div>
            ) : (
              logs.map((entry) => (
                <div className="log-entry" key={entry.id}>
                  <span className="timestamp">
                    {formatTimestamp(entry.timestamp)}
                  </span>
                  <span className="message">{entry.line}</span>
                  {entry.labels && (
                    <span className="labels">{formatLabels(entry.labels)}</span>
                  )}
                </div>
              ))
            )}
          </div>
        </div>
      </div>
    </div>
  );
};
