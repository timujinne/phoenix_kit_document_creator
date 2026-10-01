# Claude Review — PR #62

Keep the selected category in the Categories page URL
(`?category=<uuid>`). Author: Timujeen. Reviewed the merge diff
(`3abcc13..fc62388`) — `Paths.category/1`, `CategoriesLive`, the
category / type / preset forms and `Web.Helpers.category_crumb/2`.

Checked and correct:

- **URL-driven state lives in `handle_params/3`, not `mount/3`.** `mount/3`
  still only sets empty assigns and subscribes; `put_selected/2` then
  `reload_categories/1` run per navigation. No query moved into `mount`.
- **The URL value is never trusted.** `put_selected/2` stores only a
  `%{uuid: uuid}` stub and `reload_categories/1` resolves it against the
  list it just loaded, so a malformed, unknown, or other-status-tab uuid
  selects nothing and never reaches a DB cast (the "not-a-uuid" test
  covers it). Non-binary params (`?category[]=x`) fall through to `nil`.
- **`push_patch` stays on the same LiveView.** `selected_path/2` builds
  from the request path (locale prefix included), and flashes put before a
  patch survive it (asserted).
- **Re-selecting the current category** still leaves the types' Trash tab:
  `select_category` assigns `types_status_mode: "active"` before patching
  because `put_selected/2` deliberately keeps state when the uuid is
  unchanged. Tested.
- **Form redirects.** New category (`uuid == nil`) falls back to the plain
  list via `Paths.category(nil)`; type save/delete return to the type's
  *current* category (the form can move it); the back link and Cancel use
  the record as loaded. The preset form reads the category from assigns.
- **Query encoding** goes through `URI.encode_query/1` in both helpers.

## NITPICK — restoring the selected category leaves `?category=` in the URL

In the categories Trash tab, `restore_category` calls `reload_categories/1`
directly. If the restored category was the selected one it leaves the
Trash list, `selected` becomes `nil`, but the URL still says
`?category=<uuid>`. Trash and Delete Forever already patch to the bare
path. Harmless (a reload opens the restored category in the Active tab,
which is arguably what the URL says), so left as is: patching only when
the restored row is the selected one adds a branch for a cosmetic gap.

## NITPICK — the Trash tab is not part of the URL

`?category=<uuid>` of a trashed category opens the Active tab on reload,
where that category is absent, so nothing is selected. `put_selected/2`'s
comment records this ("in the other status tab"). Adding `&status=trashed`
would be a second URL param for a rarely reloaded state; not added.

## NITPICK — one extra categories query per click

`select_category` now goes patch → `handle_params/3` → `reload_categories/1`,
which re-lists categories and re-counts trashed ones where the old click
reloaded only types, and `with_category/3` has already fetched the row
once. Two cheap indexed queries per click on an admin-only page; the
uniform path (click, link, Back, reload all take the same code) is worth
more than the saving.

No code changes made. Gate: see FOLLOW_UP.md.
