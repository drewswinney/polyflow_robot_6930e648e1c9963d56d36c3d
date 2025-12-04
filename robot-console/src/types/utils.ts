export type StatusState = "idle" | "saving" | "success" | "error";

export interface WifiBody {
  ssid: string;
  psk?: string;
}

export interface WifiStatusResponse {
  configured: boolean;
  ssid: string | null;
  pskSet: boolean;
}

export interface SystemStatsResponse {
  robotName: string;
  cpuUsage: number;
  ramUsage: number;
  temperatureC?: number | null;
}
