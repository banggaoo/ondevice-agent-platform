"""Conservative development bounds, mirroring PlatformLimits.swift."""


class PlatformLimits:
    ACTIVE_INFERENCE = 1
    PENDING_INFERENCE = 4
    REQUEST_BODY_BYTES = 24 * 1024 * 1024
    REQUEST_HEADER_BYTES = 16 * 1024
    CONNECTIONS = 32
    CONNECTION_READ_SECONDS = 5.0
    # Agent-sized generations can run minutes on a small local model; the
    # deadline is a runaway bound, not a latency target.
    INFERENCE_DEADLINE_SECONDS = 300.0
    # Queued work survives resource deferrals (fair thermal, low power) for
    # this long; deferrals re-evaluate on each resource sample.
    QUEUE_DEADLINE_SECONDS = 60.0
    CANCELLATION_GRACE_SECONDS = 5.0
    RESOURCE_SAMPLE_SECONDS = 1.0
    RESOURCE_MAX_AGE_SECONDS = 5.0
    # A loaded model container unused for this long is released so its
    # memory returns to the host; the next request reloads on demand.
    MODEL_IDLE_SECONDS = 600.0
    # Global ceiling and default for one completion; per-profile caps lower.
    OUTPUT_TOKENS = 8192
    CHAT_MESSAGES = 256
    CHAT_TEXT_BYTES = 256 * 1024
    # Declared tool definitions per request and calls per assistant message.
    CHAT_TOOLS = 64
    CHAT_TOOL_CALLS_PER_MESSAGE = 16
    CHAT_IMAGES_PER_REQUEST = 4
    # Decoded image bytes per request (base64 is undone before this counts).
    CHAT_IMAGE_BYTES = 16 * 1024 * 1024
    # Conservative input bounds, not a calibrated device-memory guarantee.
    CHAT_IMAGE_DIMENSION = 8192
    CHAT_IMAGE_PIXELS = 8 * 1024 * 1024
    AGENT_PROMPT_BYTES = 16 * 1024
    AGENT_DEADLINE_SECONDS = 120.0
    AGENT_GENERATED_TOKEN_RESERVATIONS = 2048
    AGENT_TOOL_ROUNDS = 6
    ML_INPUT_BYTES = 16 * 1024
    AGENT_CONNECTIONS = 16
    SESSIONS_PER_CONNECTION = 8
    CONSOLE_SESSIONS = 8
    CONSOLE_SESSION_SECONDS = 15 * 60
    EVENT_SUBSCRIBERS = 8
    LOGIN_ATTEMPTS_PER_MINUTE = 10
    REQUESTS_PER_CONSUMER_PER_MINUTE = 120
    DURABLE_RECORDS = 1000
    DATABASE_BYTES = 16 * 1024 * 1024
