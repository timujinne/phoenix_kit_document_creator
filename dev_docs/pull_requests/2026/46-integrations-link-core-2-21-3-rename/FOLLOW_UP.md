# Follow-up — PR #46

Added 2026-09-13 during the weekly review. `CLAUDE_REVIEW.md` reported no
findings; one was missed.

### BUG - MEDIUM — the new links are only correct on core 2.21.3+, but the pin admitted core 2.4

`Paths.integrations/0` and `Paths.new_integration/0` point at
`/admin/settings/integrations[/new]` as the website-wide connections page.
Core's own changelog places that path's meaning by version: 2.4–2.18 served
the **personal** page there (the exact bug 0.9.1 fixed), 2.19–2.21.2 served
the website page under `/website`, and only 2.21.3 renamed it to the bare
path. With `{:phoenix_kit, "~> 2.4"}` a host on any of those older cores
resolves 0.9.2 and gets a link that lands on the wrong page. The review
verified the path against the locked 2.22.16 only, not against the range the
pin admits.

**Resolved:** floor raised to `~> 2.21 and >= 2.21.3` in `mix.exs`, with the
reason recorded next to the dep; `core_pin_conformance_test.exs` now admits
2.21.3 / 2.22.x / 2.30.0 and rejects 2.4.0, 2.9.4, 2.18.4 and 2.21.2;
`AGENTS.md` updated in both places that quoted the old floor. This is a
consumer-facing requirement change and belongs in the next release's
CHANGELOG entry.
