# ─────────────────────────────────────────────
#  Tokio — L4 Advanced Stresser
#  Configuration
# ─────────────────────────────────────────────

# ── Attack Parameters ─────────────────────────
# Number of concurrent connections sent per endpoint
DEFAULT_CONNECTIONS: int = 2000

# Attack duration in seconds
DEFAULT_DURATION: int = 30

# ── Lock & Cooldown ───────────────────────────
# How long (seconds) the backend stays locked after a deploy.
# Should be DEFAULT_DURATION + safety buffer.
# Example: 30s attack + 15s buffer = 45s
ATTACK_LOCK_SECONDS: int = 45

# Per-user cooldown in seconds (owner exempt)
COOLDOWN_SECONDS: int = 30

# ── Embed ─────────────────────────────────────
EMBED_COLOR: int = 0xFF8C00
BRAND_FOOTER: str = "Tokio — L4 Advanced Stresser"

# ── HTTP / API ────────────────────────────────
# Seconds to wait for a TCP connection to an endpoint
HTTP_TIMEOUT_CONNECT: float = 3.0

# Total seconds allowed for a full API request
HTTP_TIMEOUT_TOTAL: float = 6.0

# Max simultaneous outbound connections across all endpoints
HTTP_CONNECTOR_LIMIT: int = 256

# Keep connections alive for N seconds between requests
HTTP_KEEPALIVE_TIMEOUT: int = 30
