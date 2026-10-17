# PR #63 — OTP 28 compatibility and legacy migration idempotence

Merged 2026-10-17 from mdon/main. Raises the PhoenixKit requirement to
`>= 2.43.0 and < 3.0.0`, locks core 2.62.2, removes obsolete integration API
compatibility branches, and fixes the boot migration's handling of core's
`{:ok, uuid}` lookup result. Test configuration and the image picker's fallback
path are updated for the resolved core.

See `CLAUDE_REVIEW.md` for the first review, `GPT_REVIEW.md` for the second
review and migration recovery fixes, and `FOLLOW_UP.md` for resolutions and
validation.
