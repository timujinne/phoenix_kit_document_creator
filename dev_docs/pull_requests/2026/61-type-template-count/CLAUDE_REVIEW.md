# Claude Review — PR #61

Show the number of published templates next to each document type on the
Categories page. Author: Timujeen. Reviewed the merge diff
(`3906668..e2ee512`) against the broadcast sites in `Documents`,
`Taxonomy` and `DocumentsLive`.

Checked and correct:

- **One query per reload, no N+1.** `Taxonomy.count_published_templates_by_type/1`
  groups over the membership table for the whole visible type list; the
  empty-list clause skips the round trip. No DB work moved into `mount/3`.
- **The count agrees with what the preset editor shows.** It joins `Type` on
  `ty.category_uuid == m.category_uuid`, so a membership stranded under the
  old category after a type moves is not counted — and
  `list_templates_for_category/1` of the new category does not return it
  either. The old category no longer lists the type, so the stricter join is
  never visible as a disagreement.
- **Live refresh triggers exist for the changes that matter.** Memberships
  (`set_template_memberships/2`) and the cascades (`trash_*` / `restore_*`
  bulk-updating `templates.status`) broadcast `:doc_taxonomy_changed`, which
  already reloads the page. Trashing and restoring a single template from
  `DocumentsLive` broadcasts `{:files_changed, pid}`, now handled here.
- **Trash view carries no count**, and the `:if` keeps the badge id out of
  the DOM so the test's `refute has_element?` is meaningful.
- **Russian plural has all three forms**; the `et` / `en` catalogues are
  complete.
- **Test synchronisation.** `PubSub.broadcast` sends from the caller, so the
  message is in the LiveView's mailbox before `:sys.get_state/1`'s call —
  the `_ = :sys.get_state(view.pid)` barrier is sound.

## IMPROVEMENT - MEDIUM — no catch-all `handle_info/2` after subscribing to the files topic

`CategoriesLive` now subscribes to `"document_creator:files"`, a topic the
AGENTS.md contract table documents for consumers. Its only clauses were
`{:doc_taxonomy_changed, _, _}` and `{:files_changed, _}`; any other message
on either topic raised `FunctionClauseError` and crashed the admin page.
`DocumentsLive`, the other subscriber, has a debug-logging catch-all for
exactly this reason.

**Fixed.** Added the same catch-all; new LiveView test broadcasts a stray
message and asserts the page is alive and still renders the count.

## IMPROVEMENT - MEDIUM — Drive-sync status changes do not refresh the counts live

`sync_from_drive/0` → `reconcile_status/3` moves templates between
`published`, `lost`, `trashed` and `unfiled` (and the upsert flips a
reappearing file back to `published`) without any broadcast, and
`DocumentsLive`'s `:sync_complete` does not broadcast either. An open
Categories page keeps its counts until the next reload or taxonomy event.

**Not fixed.** A broadcast at the end of every sync would make every
connected `DocumentsLive` resync on every other session's sync — two open
tabs would ping-pong, gated only by the cooldown. Doing it right needs
`reconcile_status/3` and the upserts to report whether any status actually
changed and broadcast only then; that is a sync-layer change well outside a
count badge. Stale-until-reload for a Drive-side move is acceptable here.

## NITPICK — docstring overstated "the same rule as `list_templates_for_category/1`"

`list_templates_for_category/1` has no `Type` join, so for the *old*
category it still returns a membership stranded by a type move, which the
count ignores. The docstring said the moved membership "counts for
neither", implying both functions agree on it.

**Fixed.** Reworded to state what the count does and where it deliberately
differs.

## NITPICK — `role="img"` on a text badge

A numeric badge with `role="img"` plus `aria-label` works (screen readers
read "2 templates" instead of "2"), but a visually-hidden text span is the
more conventional pattern.

**Not changed.** It behaves correctly and the tests pin the label.
