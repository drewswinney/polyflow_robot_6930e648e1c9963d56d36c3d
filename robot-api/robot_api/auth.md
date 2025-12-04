Auth model (current):
- Bearer token stored at /var/lib/polyflow/api_token (create if missing).
- ENV overrides:
  - ROBOT_API_TOKEN_PATH: token file path.
  - ROBOT_API_ALLOWED_ORIGINS: comma-separated list for CORS (optional; if empty, CORS disabled).
- Health endpoint is unauthenticated; all others require Authorization: Bearer <token>.
- Requests from loopback, link-local, or other private network addresses (e.g., 127.0.0.1, 10.x.x.x, 192.168.x.x) are trusted and may call the API without the token. Everyone else must provide the header.
- Token is plain text; you can rotate by replacing the file and restarting the service.
