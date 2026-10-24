# PR #38 — Multi-category template membership + canonical group-order seed

**Reviewed:** 2026-08-13 · **Author:** @timujinne · **Verdict:** merged unchanged.

## Summary

Replaces a template's single `category_uuid`/`type_uuid` binding with a
many-to-many join (`phoenix_kit_doc_template_taxonomy`), keeps the legacy
columns as a mirror of the primary membership for the host-app consumer, adds
migration chain V2 with a backfill, and seeds the nine canonical groups.

The PR had already been through two adversarial review rounds (`e64239e`,
`c9b6d8b`) and its "Known follow-ups" list is honest and specific. I re-derived
the load-bearing parts rather than trusting that, and found nothing blocking.

## The migration — verified against this workspace's prefix rules

Core's prefix-safe migration rules are unforgiving, and this chain follows them:

- **Index names stay bare on `CREATE`**, qualified only on drop. All three
  `CREATE ... INDEX IF NOT EXISTS <bare name> ON #{p}table` — correct. Under a
  named-schema install the index resolves into the table's schema, so two
  prefixed installs in one database each get their own.
- **`down/1` updates the marker to `target`**, and drops before it stamps, so a
  failure can never strand a "marker present, table gone" state. Ecto wraps
  `down/1` in a DDL transaction here (no `@disable_ddl_transaction`), so it is
  atomic. The moduledoc's ⚠️ about `down(target: 1)` destroying all
  multi-category data is accurate and worth having written down.
- **`up/1` is idempotent** — `CREATE TABLE IF NOT EXISTS`, `IF NOT EXISTS` on
  every index, and the backfill's `ON CONFLICT (template_uuid, category_uuid)
  DO NOTHING` riding the unique index. Re-running is a no-op.
- **The `COMMENT` note contains no apostrophe**, so the single-quoted SQL
  literal is well-formed. Worth checking because a deprecation note is exactly
  the kind of prose that acquires one later — anyone editing it must escape.
- **`p` comes from `validated_prefix/1`.**

## The core-owned-table trap does not apply here

This workspace's AGENTS.md rule #5 is that a module must not create a table
core's chain already ships (`phoenix_kit_legal` shipped in that state until
0.3.0). V2 creates a genuinely new table and otherwise only `COMMENT`s on
existing columns — it adopts nothing core owns. Clean.

## The mirror logic — traced, correct

This is where a bug would hide, since two representations must agree.

- `set_template_memberships/3` does delete-all + insert-all + mirror **inside one
  `repo().transaction/1`**, so a partial write cannot leave the join and the
  mirror disagreeing.
- `recompute_mirrors/1` is likewise called **inside** the `trash_category`
  transaction (and the restore/type equivalents), not after it.
- `mirror_primary_membership/2` picks the lowest `Category.position`, breaking
  ties on `category_uuid` for a stable choice. A category with no position row
  gets `2_147_483_647`; a category whose `position` is `NULL` in the database
  yields `nil`, which Erlang term ordering sorts after every integer — so both
  "no position" spellings land last, which is the documented intent.
- `recompute_mirrors/1` filters to `c.status != "deleted"` and nulls a
  soft-deleted group's `type_uuid` in the mirror while leaving the join row
  intact, so a restore brings the group back. That asymmetry is deliberate and
  is what makes trash+restore round-trip.

## NITPICK — not changed

- **The backfill mints UUIDv4.** `gen_random_uuid()` where this workspace's
  convention is `uuid_generate_v7()`, so backfilled join rows carry v4 PKs while
  app-inserted ones carry v7 (the schema uses `@primary_key {:uuid, UUIDv7, ...}`).
  Defensible here and arguably the safer choice: `gen_random_uuid()` is a
  `pg_catalog` builtin needing no `Helpers.ensure_uuid_v7_function/1` +
  `uuid_v7_call/1` dance under a named schema, and these PKs are never surfaced
  by id or sorted on. Worth knowing the mix exists.
- **`recompute_mirrors/1` is O(N) queries.** One membership query plus one or two
  mirror queries per affected template, so trashing a category with many
  templates costs ~3N round trips. Correct, and each is trivial; it would become
  worth batching only on a category holding hundreds of templates.

## Follow-ups the PR names and I agree with

The four accepted follow-ups (FK-driven permanent delete leaving a lazily
realigned mirror; no DB-level mirror⇔join constraint; the seed duplicating a
soft-deleted canonical group because `Type` has no unique index on
`(name, category_uuid)`; the cosmetic stale membership row after trash) are all
real, all correctly characterised as non-blocking, and all cheaper to fix once
the host app migrates and the legacy columns can be dropped outright. The missing unique
index on `Type(name, category_uuid)` is the one most likely to bite first.
