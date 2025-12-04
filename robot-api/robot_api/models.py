from pydantic import BaseModel, Field


class WifiRequest(BaseModel):
    ssid: str = Field(..., min_length=1)
    psk: str | None = None


class WifiStatus(BaseModel):
    configured: bool
    ssid: str | None = None
    pskSet: bool = False


class SystemStats(BaseModel):
    robotName: str
    cpuUsage: float
    ramUsage: float
    temperatureC: float | None = None
