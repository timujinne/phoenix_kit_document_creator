# Follow-up — PR #51

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-21 and released in 0.9.6.

### IMPROVEMENT - MEDIUM — margins read from `documentStyle` only

**Resolved.** `section_margin_requests/2` reads the template's first
section's `sectionStyle` margins first and falls back to `documentStyle` per
field (`first_section_style/1`). Explicit-zero handling (`%{"unit" => "PT"}`)
applies to both sources through the same `dimension_or_nil/1`.

### NITPICK — no stated margins inherits the previous section's

**Not changed.** Theoretical for real Google Docs responses.
