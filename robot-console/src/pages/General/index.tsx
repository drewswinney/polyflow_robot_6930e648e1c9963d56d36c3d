import { Label } from "@polyflowrobotics/ui-components";
import { useEffect, useMemo, useState } from "react";
import { SystemStatsResponse } from "../../types/utils";
import { API_BASE } from "../../config";
import "./general.scss";

export const GeneralPage = () => {
  // API is reverse-proxied by Caddy under the same origin at /api unless overridden via env
  const apiBase = useMemo(() => API_BASE, []);
  const [stats, setStats] = useState<SystemStatsResponse | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;

    const fetchStats = async () => {
      try {
        const res = await fetch(`${apiBase}/stats`);
        if (!res.ok) {
          const msg = await res.text();
          throw new Error(msg || "Failed to load stats");
        }
        const data: SystemStatsResponse = await res.json();
        if (!active) return;
        setStats(data);
        setError("");
      } catch (err: any) {
        if (!active) return;
        setError(err?.message || "Failed to load stats");
      }
    };

    fetchStats();
    const interval = window.setInterval(fetchStats, 15000);
    return () => {
      active = false;
      window.clearInterval(interval);
    };
  }, [apiBase]);

  const formatCpu = stats ? `${stats.cpuUsage.toFixed(1)}%` : "—";
  const formatRam = stats ? `${stats.ramUsage.toFixed(1)}%` : "—";
  const formatTemp =
    stats && stats.temperatureC != null
      ? `${stats.temperatureC.toFixed(1)} °C`
      : "N/A";

  return (
    <div className="body">
      <div className="form">
        <div className="group">
          <div className="group-header">Robot Information</div>
          <div className="field">
            <Label>Robot ID</Label>
            <div className="value">{stats?.robotName ?? "—"}</div>
          </div>
          <div className="field">
            <Label>CPU Usage</Label>
            <div className="value">{formatCpu}</div>
          </div>
          <div className="field">
            <Label>RAM Usage</Label>
            <div className="value">{formatRam}</div>
          </div>
          <div className="field">
            <Label>Temperature</Label>
            <div className="value">{formatTemp}</div>
          </div>
          {error && <div className="error-text">{error}</div>}
        </div>
      </div>
      <div className="footer"></div>
    </div>
  );
};
