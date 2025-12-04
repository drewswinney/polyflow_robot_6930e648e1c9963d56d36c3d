import {
  TextField,
  Button,
  Card,
  Variant,
  Alert,
} from "@polyflowrobotics/ui-components";
import { useEffect, useMemo, useState } from "react";
import { StatusState, WifiBody, WifiStatusResponse } from "../../types/utils";
import { API_BASE } from "../../config";
import "./connection.scss";

export const ConnectionPage = () => {
  const [ssid, setSsid] = useState("");
  const [password, setPassword] = useState("");
  const [status, setStatus] = useState<StatusState>("idle");
  const [statusMessage, setStatusMessage] = useState("");

  // API is reverse-proxied by Caddy under the same origin at /api unless overridden via env
  const apiBase = useMemo(() => API_BASE, []);

  useEffect(() => {
    const fetchStatus = async () => {
      try {
        const res = await fetch(`${apiBase}/wifi`);
        if (!res.ok) return;
        const data: WifiStatusResponse = await res.json();
        if (data.configured) {
          setSsid(data.ssid || "");
          setPassword(data.pskSet ? "********" : "");
        }
      } catch (err) {
        // ignore initial load errors
        console.error(err);
      }
    };
    fetchStatus();
  }, [apiBase]);

  const handleSave = async () => {
    if (!ssid) {
      setStatus("error");
      setStatusMessage("SSID is required");
      return;
    }
    setStatus("saving");
    setStatusMessage("");
    try {
      const body: WifiBody = { ssid, psk: password || undefined };
      const res = await fetch(`${apiBase}/wifi`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const msg = await res.text();
        throw new Error(msg || "Failed to save");
      }
      setStatus("success");
      setStatusMessage("Saved. Switching modes...");
    } catch (err: any) {
      setStatus("error");
      setStatusMessage(err?.message || "Failed to save");
    }
  };

  return (
    <div className="body">
      <div className="form">
        <div className="group">
          <div className="group-header">Wifi Settings</div>
          <TextField
            label="SSID"
            value={ssid}
            onChange={(value) => setSsid(value)}
          />
          <TextField
            label="Password"
            type="password"
            value={password}
            onChange={(value) => setPassword(value)}
          />
        </div>
        <div className="group">
          <div className="group-header">Bluetooth Settings</div>
          <Card className="coming-soon">Coming Soon</Card>
        </div>
      </div>
      <div className="footer">
        {statusMessage && (
          <Alert className="alert" variant={Variant.Error}>
            {statusMessage}
          </Alert>
        )}
        <Button
          variant={Variant.Primary}
          onClick={handleSave}
          disabled={status === "saving"}
        >
          {status === "saving" ? "Saving..." : "Save configuration"}
        </Button>
      </div>
    </div>
  );
};
