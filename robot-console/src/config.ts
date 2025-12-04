const DEFAULT_API_BASE = "/api";

const computeApiBase = () => {
  const raw = (import.meta.env.VITE_API_BASE_URL as string | undefined)?.trim();
  if (!raw) {
    return DEFAULT_API_BASE;
  }
  // Keep trailing path consistent; drop trailing slash to avoid // in fetches
  const normalized = raw.replace(/\/+$/, "");
  return normalized || DEFAULT_API_BASE;
};

export const API_BASE = computeApiBase();
