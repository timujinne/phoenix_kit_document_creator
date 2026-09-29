defmodule PhoenixKitDocumentCreator.Taxonomy do
  @moduledoc """
  Context module for managing the Document Creator Category → Type hierarchy.

  Provides CRUD, cascade soft-delete/restore, reorder, and picker helpers
  for `Category` and `Type` schemas. Modeled on
  `PhoenixKitCatalogue.Catalogue`.

  ## Soft-Delete Cascade

  - `trash_category/1` — soft-deletes the category, all its types, and all
    templates reachable via `category_uuid` or `type_uuid`. Records affected
    template uuids in the activity log so `restore_category/1` can scope its
    restore precisely.
  - `trash_type/1` — soft-deletes the type and templates whose `type_uuid`
    points at it.
  - Documents are **never** cascaded; they keep pointing at their (now
    trashed) category and remain usable.

  ## PubSub

  Every successful write broadcasts `{:doc_taxonomy_changed, level, uuid}`
  on the shared PhoenixKit PubSub. `level` is `:category` or `:type`.
  Consumers subscribe via `PhoenixKit.PubSubHelper.subscribe/1`.
  """

  import Ecto.Query, warn: false

  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitDocumentCreator.Schemas.Category
  alias PhoenixKitDocumentCreator.Schemas.Template
  alias PhoenixKitDocumentCreator.Schemas.TemplateTaxonomy
  alias PhoenixKitDocumentCreator.Schemas.Type

  @module_key "document_creator"
  @pubsub_topic "document_creator:taxonomy"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  @doc "Subscribes the caller to taxonomy change events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.subscribe(@pubsub_topic)
    else
      :ok
    end
  end

  defp broadcast(level, uuid) when is_atom(level) do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.broadcast(@pubsub_topic, {:doc_taxonomy_changed, level, uuid})
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Activity logging
  # ---------------------------------------------------------------------------

  defp log_activity(attrs) do
    PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))

    :ok
  end

  # ---------------------------------------------------------------------------
  # Category — list / get
  # ---------------------------------------------------------------------------

  @doc """
  Lists categories ordered by position then name.

  ## Options

    * `:status` — when provided, returns only categories with this exact
      status (e.g. `"active"`, `"deleted"`). When nil (default), returns
      all non-deleted categories.
  """
  @spec list_categories(keyword()) :: [Category.t()]
  def list_categories(opts \\ []) do
    from(c in Category, order_by: [asc: c.position, asc: c.name])
    |> apply_status_filter(opts)
    |> repo().all()
  end

  # An explicit `:status` matches exactly; nil (the default) excludes
  # soft-deleted rows. Shared by the list_* and count_* functions.
  defp apply_status_filter(query, opts) do
    case Keyword.get(opts, :status) do
      nil -> where(query, [r], r.status != "deleted")
      status -> where(query, [r], r.status == ^status)
    end
  end

  @doc """
  Counts categories, applying the same `:status` filter semantics as
  `list_categories/1`. Counts in SQL instead of loading rows — use when only
  the number is needed (e.g. a "Trash (N)" badge).
  """
  @spec count_categories(keyword()) :: non_neg_integer()
  def count_categories(opts \\ []) do
    Category
    |> apply_status_filter(opts)
    |> repo().aggregate(:count)
  end

  @doc "Fetches a category by UUID. Returns `nil` if not found."
  @spec get_category(Ecto.UUID.t()) :: Category.t() | nil
  def get_category(uuid), do: repo().get(Category, uuid)

  @doc "Fetches a category by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_category!(Ecto.UUID.t()) :: Category.t()
  def get_category!(uuid), do: repo().get!(Category, uuid)

  # ---------------------------------------------------------------------------
  # Category — write
  # ---------------------------------------------------------------------------

  @doc """
  Creates a category.

  ## Required attributes

    * `:name` — category name (1-255 chars)

  ## Optional attributes

    * `:description`, `:position` (default: appended after the last active
      category), `:status` (default `"active"`), `:data`
  """
  @spec create_category(map(), keyword()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t(Category.t())}
  def create_category(attrs, opts \\ []) do
    attrs = put_default_position(attrs, &next_category_position/0)

    case %Category{} |> Category.changeset(attrs) |> repo().insert() do
      {:ok, category} = ok ->
        log_activity(%{
          action: "doc_taxonomy.category.created",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "doc_category",
          resource_uuid: category.uuid,
          metadata: %{"name" => category.name}
        })

        broadcast(:category, category.uuid)
        ok

      error ->
        error
    end
  end

  @doc "Updates a category with the given attributes."
  @spec update_category(Category.t(), map(), keyword()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t(Category.t())}
  def update_category(%Category{} = category, attrs, opts \\ []) do
    case category |> Category.changeset(attrs) |> repo().update() do
      {:ok, updated} = ok ->
        log_activity(%{
          action: "doc_taxonomy.category.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "doc_category",
          resource_uuid: updated.uuid,
          metadata: %{"name" => updated.name}
        })

        broadcast(:category, updated.uuid)
        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a category by setting its status to `"deleted"`.

  **Cascades in one transaction:**
  1. Category `status → "deleted"`
  2. Its currently-active types `status → "deleted"`
  3. All templates reachable via `category_uuid` (directly) or via any of
     the category's `type_uuid` values → `status → "trashed"`

  Documents are NOT cascaded.

  Affected type and template uuids are stored in the activity log payload
  so `restore_category/1` restores only what this cascade trashed — types
  the user had already trashed manually stay trashed.
  """
  @spec trash_category(Category.t(), keyword()) :: {:ok, Category.t()} | {:error, term()}
  def trash_category(%Category{} = category, opts \\ []) do
    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        # Every type under this category, with its status. `type_uuids` (all)
        # is used to find templates via `type_uuid`; `cascade_type_uuids` (the
        # still-active ones) are the only types this cascade trashes — and so
        # the only ones `restore_category/1` should restore.
        types =
          from(t in Type,
            where: t.category_uuid == ^category.uuid,
            select: {t.uuid, t.status}
          )
          |> repo().all()

        type_uuids = Enum.map(types, &elem(&1, 0))
        cascade_type_uuids = for {uuid, status} <- types, status != "deleted", do: uuid

        # Collect template uuids to be trashed — only those currently active,
        # to avoid recording templates the user already trashed manually.
        # Exclude templates that still belong to ANOTHER active category via a
        # membership (V2): a multi-category template must survive when just one
        # of its categories is trashed.
        template_uuids =
          from(tmpl in Template,
            where:
              (tmpl.category_uuid == ^category.uuid or
                 tmpl.type_uuid in ^type_uuids) and
                tmpl.status != "trashed",
            select: tmpl.uuid
          )
          |> repo().all()
          |> reject_templates_in_other_active_category(category.uuid)

        # Trash the types this cascade is responsible for.
        unless cascade_type_uuids == [] do
          from(t in Type, where: t.uuid in ^cascade_type_uuids)
          |> repo().update_all(set: [status: "deleted", updated_at: now])
        end

        # Trash templates via category_uuid or type_uuid.
        unless template_uuids == [] do
          from(tmpl in Template, where: tmpl.uuid in ^template_uuids)
          |> repo().update_all(set: [status: "trashed", updated_at: now])
        end

        updated =
          category
          |> Category.changeset(%{status: "deleted"})
          |> repo().update!()

        # Recompute the legacy mirror for every template that had a membership
        # in this category, now that it is deleted: survivors move to their next
        # active category, sole-category templates clear to nil. Keeps the
        # mirror from pointing at a trashed category (which would hide a
        # multi-category template from legacy single-category readers).
        recompute_mirrors(membership_template_uuids(category_uuid: category.uuid))

        {updated, template_uuids, cascade_type_uuids}
      end)

    with {:ok, {updated, trashed_template_uuids, trashed_type_uuids}} <- result do
      log_activity(%{
        action: "doc_taxonomy.category.trashed",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "doc_category",
        resource_uuid: category.uuid,
        metadata: %{
          "name" => category.name,
          "cascade_template_uuids" => trashed_template_uuids,
          "cascade_type_uuids" => trashed_type_uuids
        }
      })

      broadcast(:category, category.uuid)
      {:ok, updated}
    end
  end

  @doc """
  Restores a soft-deleted category.

  **Cascades in one transaction:**
  1. Category `status → "active"`
  2. Types whose uuids were recorded in the trash activity log
     `status → "active"` (only those, so types the user had trashed
     manually before the cascade stay trashed)
  3. Templates whose uuids were recorded in the trash activity log
     `status → "published"` (only those, to avoid restoring manually
     trashed templates)

  When `PhoenixKit.Activity` is not loaded (or no matching activity entry
  exists), cascade-trashed types and templates are not restored — they
  must be restored manually.
  """
  @spec restore_category(Category.t(), keyword()) :: {:ok, Category.t()} | {:error, term()}
  def restore_category(%Category{} = category, opts \\ []) do
    %{templates: cascade_template_uuids, types: cascade_type_uuids} =
      fetch_cascade_uuids(:category, category.uuid)

    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        # Restore only the types this cascade trashed.
        unless cascade_type_uuids == [] do
          from(t in Type,
            where:
              t.category_uuid == ^category.uuid and
                t.uuid in ^cascade_type_uuids and
                t.status == "deleted"
          )
          |> repo().update_all(set: [status: "active", updated_at: now])
        end

        # Restore only templates that were trashed by the cascade.
        unless cascade_template_uuids == [] do
          from(tmpl in Template,
            where: tmpl.uuid in ^cascade_template_uuids and tmpl.status == "trashed"
          )
          |> repo().update_all(set: [status: "published", updated_at: now])
        end

        restored =
          category
          |> Category.changeset(%{status: "active"})
          |> repo().update!()

        # Now that the category is active again, its members can reclaim it as
        # their primary mirror where appropriate.
        recompute_mirrors(membership_template_uuids(category_uuid: category.uuid))

        restored
      end)

    with {:ok, updated} <- result do
      log_activity(%{
        action: "doc_taxonomy.category.restored",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "doc_category",
        resource_uuid: category.uuid,
        metadata: %{"name" => category.name}
      })

      broadcast(:category, category.uuid)
      {:ok, updated}
    end
  end

  @doc """
  Permanently deletes a category and all its types from the database.

  Relies on `ON DELETE CASCADE` for child types and `ON DELETE SET NULL` for
  template/document FK columns.
  """
  @spec permanently_delete_category(Category.t(), keyword()) ::
          {:ok, Category.t()} | {:error, term()}
  def permanently_delete_category(%Category{} = category, opts \\ []) do
    case repo().delete(category) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "doc_taxonomy.category.permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "doc_category",
          resource_uuid: category.uuid,
          metadata: %{"name" => category.name}
        })

        broadcast(:category, category.uuid)
        ok

      error ->
        error
    end
  end

  @doc """
  Reorders categories by assigning positions from the given ordered list.

  Each uuid in the list gets `position = index`. UUIDs not present keep
  their existing positions.
  """
  @spec reorder_categories([Ecto.UUID.t()], keyword()) :: :ok | {:error, term()}
  def reorder_categories(ordered_uuids, opts \\ []) when is_list(ordered_uuids) do
    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        ordered_uuids
        |> Enum.with_index()
        |> Enum.each(fn {uuid, position} ->
          from(c in Category, where: c.uuid == ^uuid)
          |> repo().update_all(set: [position: position, updated_at: now])
        end)
      end)

    case result do
      {:ok, _} ->
        log_activity(%{
          action: "doc_taxonomy.category.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "doc_category",
          metadata: %{"count" => length(ordered_uuids)}
        })

        broadcast(:category, nil)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Type — list / get
  # ---------------------------------------------------------------------------

  @doc """
  Lists types for a category ordered by position then name.

  ## Options

    * `:status` — when provided, returns only types with this exact status.
      Defaults to non-deleted types.
  """
  @spec list_types_for_category(Ecto.UUID.t(), keyword()) :: [Type.t()]
  def list_types_for_category(category_uuid, opts \\ []) do
    from(t in Type,
      where: t.category_uuid == ^category_uuid,
      order_by: [asc: t.position, asc: t.name]
    )
    |> apply_status_filter(opts)
    |> repo().all()
  end

  @doc """
  Counts types for a category, applying the same `:status` filter semantics as
  `list_types_for_category/2`. Counts in SQL instead of loading rows.
  """
  @spec count_types_for_category(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def count_types_for_category(category_uuid, opts \\ []) do
    from(t in Type, where: t.category_uuid == ^category_uuid)
    |> apply_status_filter(opts)
    |> repo().aggregate(:count)
  end

  @doc """
  Counts published templates per group, keyed by type uuid.

  Counted through the `phoenix_kit_doc_template_taxonomy` memberships:
  published templates filed under the type's current category, which is
  what `PhoenixKitDocumentCreator.Documents.list_templates_for_category/1`
  returns for that category. So a template filed under several categories
  counts once in each category's group, and trashed, lost or unfiled
  templates are not counted. A membership left under the old category when
  a type moves to another one is not counted: the new category's listing
  does not return it, and the old category no longer shows the type (its
  listing still returns the row, which this count deliberately ignores).
  One query for the whole list; a type with no published template is
  absent from the map.
  """
  @spec count_published_templates_by_type([Ecto.UUID.t()]) ::
          %{Ecto.UUID.t() => pos_integer()}
  def count_published_templates_by_type([]), do: %{}

  def count_published_templates_by_type(type_uuids) when is_list(type_uuids) do
    from(m in TemplateTaxonomy,
      join: t in Template,
      on: t.uuid == m.template_uuid,
      join: ty in Type,
      on: ty.uuid == m.type_uuid and ty.category_uuid == m.category_uuid,
      where: m.type_uuid in ^type_uuids and t.status == "published",
      group_by: m.type_uuid,
      select: {m.type_uuid, count(m.template_uuid, :distinct)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc "Fetches a type by UUID. Returns `nil` if not found."
  @spec get_type(Ecto.UUID.t()) :: Type.t() | nil
  def get_type(uuid), do: repo().get(Type, uuid)

  @doc "Fetches a type by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_type!(Ecto.UUID.t()) :: Type.t()
  def get_type!(uuid), do: repo().get!(Type, uuid)

  @doc """
  Fetches a type by UUID, but only when it is currently active. Returns
  `nil` for trashed types as well as missing uuids.

  `get_type/1` returns the row regardless of status, which is correct for
  callers that need the record itself (e.g. restoring or permanently
  deleting it) but wrong for anywhere a type's name is rendered as a live
  label for end users — that would surface a soft-deleted type's name as
  if it were still a normal, selectable option. Use `get_active_type/1` in
  those spots instead.
  """
  @spec get_active_type(Ecto.UUID.t()) :: Type.t() | nil
  def get_active_type(uuid) do
    case get_type(uuid) do
      %Type{status: "active"} = type -> type
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Type — write
  # ---------------------------------------------------------------------------

  @doc """
  Creates a type.

  ## Required attributes

    * `:name` — type name (1-255 chars)
    * `:category_uuid` — parent category

  ## Optional attributes

    * `:description`, `:position` (default: appended after the last active
      type in the same category), `:status`, `:data`
  """
  @spec create_type(map(), keyword()) ::
          {:ok, Type.t()} | {:error, Ecto.Changeset.t(Type.t())}
  def create_type(attrs, opts \\ []) do
    attrs =
      put_default_position(attrs, fn ->
        # The position lookup runs before the changeset, so a blank or
        # malformed uuid (e.g. the form's "Select a category" prompt
        # submitting "") must not reach the query — Ecto would raise a
        # CastError instead of letting the changeset return its
        # validation error.
        with uuid when is_binary(uuid) <-
               Map.get(attrs, :category_uuid) || Map.get(attrs, "category_uuid"),
             {:ok, uuid} <- Ecto.UUID.cast(uuid) do
          next_type_position(uuid)
        else
          _ -> 0
        end
      end)

    case %Type{} |> Type.changeset(attrs) |> repo().insert() do
      {:ok, type} = ok ->
        log_activity(%{
          action: "doc_taxonomy.type.created",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "doc_type",
          resource_uuid: type.uuid,
          metadata: %{"name" => type.name, "category_uuid" => type.category_uuid}
        })

        broadcast(:type, type.uuid)
        ok

      error ->
        error
    end
  end

  @doc "Updates a type with the given attributes."
  @spec update_type(Type.t(), map(), keyword()) ::
          {:ok, Type.t()} | {:error, Ecto.Changeset.t(Type.t())}
  def update_type(%Type{} = type, attrs, opts \\ []) do
    case type |> Type.changeset(attrs) |> repo().update() do
      {:ok, updated} = ok ->
        log_activity(%{
          action: "doc_taxonomy.type.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "doc_type",
          resource_uuid: updated.uuid,
          metadata: %{"name" => updated.name}
        })

        broadcast(:type, updated.uuid)
        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a type by setting its status to `"deleted"`.

  Cascades to templates whose `type_uuid` points at this type. Affected
  template uuids are stored in the activity log.
  """
  @spec trash_type(Type.t(), keyword()) :: {:ok, Type.t()} | {:error, term()}
  def trash_type(%Type{} = type, opts \\ []) do
    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        # As in trash_category, keep multi-category templates alive: a template
        # that still belongs to another active category (via a V2 membership)
        # must not be trashed just because this group's category is affected.
        template_uuids =
          from(tmpl in Template,
            where: tmpl.type_uuid == ^type.uuid and tmpl.status != "trashed",
            select: tmpl.uuid
          )
          |> repo().all()
          |> reject_templates_in_other_active_category(type.category_uuid)

        unless template_uuids == [] do
          from(tmpl in Template, where: tmpl.uuid in ^template_uuids)
          |> repo().update_all(set: [status: "trashed", updated_at: now])
        end

        updated =
          type
          |> Type.changeset(%{status: "deleted"})
          |> repo().update!()

        # The group is deleted; clear it from the mirror of any template whose
        # mirror pointed at it (recompute nulls references to deleted types).
        recompute_mirrors(membership_template_uuids(type_uuid: type.uuid))

        {updated, template_uuids}
      end)

    with {:ok, {updated, trashed_template_uuids}} <- result do
      log_activity(%{
        action: "doc_taxonomy.type.trashed",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "doc_type",
        resource_uuid: type.uuid,
        metadata: %{
          "name" => type.name,
          "cascade_template_uuids" => trashed_template_uuids
        }
      })

      broadcast(:type, type.uuid)
      {:ok, updated}
    end
  end

  @doc """
  Restores a soft-deleted type and templates trashed by its cascade.
  """
  @spec restore_type(Type.t(), keyword()) :: {:ok, Type.t()} | {:error, term()}
  def restore_type(%Type{} = type, opts \\ []) do
    %{templates: cascade_template_uuids} = fetch_cascade_uuids(:type, type.uuid)

    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        unless cascade_template_uuids == [] do
          from(tmpl in Template,
            where: tmpl.uuid in ^cascade_template_uuids and tmpl.status == "trashed"
          )
          |> repo().update_all(set: [status: "published", updated_at: now])
        end

        restored =
          type
          |> Type.changeset(%{status: "active"})
          |> repo().update!()

        # The group is active again; let it reappear in the mirror where it is
        # the primary category's group.
        recompute_mirrors(membership_template_uuids(type_uuid: type.uuid))

        restored
      end)

    with {:ok, updated} <- result do
      log_activity(%{
        action: "doc_taxonomy.type.restored",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "doc_type",
        resource_uuid: type.uuid,
        metadata: %{"name" => type.name}
      })

      broadcast(:type, type.uuid)
      {:ok, updated}
    end
  end

  @doc """
  Permanently deletes a type from the database.

  Relies on `ON DELETE SET NULL` for template/document FK columns.
  """
  @spec permanently_delete_type(Type.t(), keyword()) ::
          {:ok, Type.t()} | {:error, term()}
  def permanently_delete_type(%Type{} = type, opts \\ []) do
    case repo().delete(type) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "doc_taxonomy.type.permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "doc_type",
          resource_uuid: type.uuid,
          metadata: %{"name" => type.name}
        })

        broadcast(:type, type.uuid)
        ok

      error ->
        error
    end
  end

  @doc """
  Reorders types within a category by assigning positions from the given
  ordered list.
  """
  @spec reorder_types(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) :: :ok | {:error, term()}
  def reorder_types(category_uuid, ordered_uuids, opts \\ [])
      when is_binary(category_uuid) and is_list(ordered_uuids) do
    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        ordered_uuids
        |> Enum.with_index()
        |> Enum.each(fn {uuid, position} ->
          from(t in Type,
            where: t.uuid == ^uuid and t.category_uuid == ^category_uuid
          )
          |> repo().update_all(set: [position: position, updated_at: now])
        end)
      end)

    case result do
      {:ok, _} ->
        log_activity(%{
          action: "doc_taxonomy.type.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "doc_type",
          metadata: %{"category_uuid" => category_uuid, "count" => length(ordered_uuids)}
        })

        broadcast(:type, nil)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Template membership (many-to-many: template ↔ category, with group)
  # ---------------------------------------------------------------------------

  @doc """
  Lists a template's category memberships (one row per category, each with
  an optional group `type_uuid`), oldest first.
  """
  @spec list_memberships_for_template(Ecto.UUID.t()) :: [TemplateTaxonomy.t()]
  def list_memberships_for_template(template_uuid) do
    from(m in TemplateTaxonomy,
      where: m.template_uuid == ^template_uuid,
      order_by: [asc: m.inserted_at, asc: m.uuid]
    )
    |> repo().all()
  end

  @doc """
  Batch variant of `list_memberships_for_template/1` for a grid render:
  returns `%{template_uuid => [%{category_uuid: _, type_uuid: _}, ...]}` for
  the given template uuids in a single query (avoids a per-row query).
  """
  @spec memberships_by_templates([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => [
            %{category_uuid: Ecto.UUID.t(), type_uuid: Ecto.UUID.t() | nil}
          ]
        }
  def memberships_by_templates([]), do: %{}

  def memberships_by_templates(template_uuids) when is_list(template_uuids) do
    from(m in TemplateTaxonomy,
      where: m.template_uuid in ^template_uuids,
      order_by: [asc: m.inserted_at, asc: m.uuid],
      select: {m.template_uuid, m.category_uuid, m.type_uuid}
    )
    |> repo().all()
    |> Enum.group_by(
      fn {template_uuid, _, _} -> template_uuid end,
      fn {_, category_uuid, type_uuid} ->
        %{category_uuid: category_uuid, type_uuid: type_uuid}
      end
    )
  end

  @doc """
  Replaces a template's full set of category memberships in one transaction.

  `memberships` is a list of maps with a `:category_uuid` (required) and an
  optional `:type_uuid` group (atom or string keys accepted). The write is
  replace-all: existing rows for the template are deleted first, then the
  given set is inserted. An empty list clears all memberships.

  After the swap, the **primary** membership — the one whose category has
  the lowest `Category.position` — is mirrored into the legacy
  `templates.category_uuid`/`type_uuid` columns so backward-compatible
  single-binding readers keep working (an empty set clears the mirror).

  Broadcasts `{:doc_taxonomy_changed, :template, template_uuid}`.
  """
  @spec set_template_memberships(Ecto.UUID.t(), [map()], keyword()) ::
          {:ok, [TemplateTaxonomy.t()]} | {:error, term()}
  def set_template_memberships(template_uuid, memberships, opts \\ [])
      when is_binary(template_uuid) and is_list(memberships) do
    normalized = Enum.map(memberships, &normalize_membership/1)

    result =
      repo().transaction(fn ->
        from(m in TemplateTaxonomy, where: m.template_uuid == ^template_uuid)
        |> repo().delete_all()

        inserted = Enum.map(normalized, &insert_membership!(template_uuid, &1))
        mirror_primary_membership(template_uuid, normalized)
        inserted
      end)

    with {:ok, rows} <- result do
      log_activity(%{
        action: "doc_taxonomy.template.memberships_set",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "template",
        resource_uuid: template_uuid,
        metadata: %{"count" => length(rows)}
      })

      broadcast(:template, template_uuid)
      {:ok, rows}
    end
  end

  # Drops from `template_uuids` any template that still has a V2 membership in
  # an active category OTHER than `except_category_uuid`. Used by the trash
  # cascades so a multi-category template survives when one of its categories
  # (or a group under it) is trashed.
  defp reject_templates_in_other_active_category([], _except_category_uuid), do: []

  defp reject_templates_in_other_active_category(template_uuids, except_category_uuid) do
    survivors =
      from(m in TemplateTaxonomy,
        join: c in Category,
        on: c.uuid == m.category_uuid,
        where:
          m.template_uuid in ^template_uuids and
            m.category_uuid != ^except_category_uuid and
            c.status != "deleted",
        select: m.template_uuid
      )
      |> repo().all()
      |> MapSet.new()

    Enum.reject(template_uuids, &MapSet.member?(survivors, &1))
  end

  # Inserts one membership row inside the replace-all transaction; rolls the
  # whole swap back if the row is invalid (e.g. a bad category FK).
  defp insert_membership!(template_uuid, attrs) do
    %TemplateTaxonomy{}
    |> TemplateTaxonomy.changeset(Map.put(attrs, :template_uuid, template_uuid))
    |> repo().insert()
    |> case do
      {:ok, row} -> row
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  # Accepts atom- or string-keyed membership maps and returns an atom-keyed
  # map suitable for `TemplateTaxonomy.changeset/2` (which rejects mixed keys).
  defp normalize_membership(%{} = m) do
    %{
      category_uuid: Map.get(m, :category_uuid) || Map.get(m, "category_uuid"),
      type_uuid: Map.get(m, :type_uuid) || Map.get(m, "type_uuid")
    }
  end

  # Mirrors the primary membership into the legacy template columns. Empty
  # membership set clears both columns.
  defp mirror_primary_membership(template_uuid, []) do
    from(t in Template, where: t.uuid == ^template_uuid)
    |> repo().update_all(
      set: [category_uuid: nil, type_uuid: nil, updated_at: DateTime.utc_now()]
    )
  end

  defp mirror_primary_membership(template_uuid, memberships) do
    cat_uuids = Enum.map(memberships, & &1.category_uuid)

    positions =
      from(c in Category, where: c.uuid in ^cat_uuids, select: {c.uuid, c.position})
      |> repo().all()
      |> Map.new()

    # Lowest category position wins; ties break on category_uuid for a stable
    # choice (a category missing a position row sorts last).
    primary =
      Enum.min_by(memberships, fn m ->
        {Map.get(positions, m.category_uuid, 2_147_483_647), m.category_uuid}
      end)

    from(t in Template, where: t.uuid == ^template_uuid)
    |> repo().update_all(
      set: [
        category_uuid: primary.category_uuid,
        type_uuid: primary.type_uuid,
        updated_at: DateTime.utc_now()
      ]
    )
  end

  # Distinct template uuids that hold a membership matching the given filter
  # (`category_uuid:` or `type_uuid:`). Used to find the templates whose mirror
  # a taxonomy trash/restore may need to recompute.
  defp membership_template_uuids(category_uuid: category_uuid) do
    from(m in TemplateTaxonomy, where: m.category_uuid == ^category_uuid, select: m.template_uuid)
    |> repo().all()
    |> Enum.uniq()
  end

  defp membership_template_uuids(type_uuid: type_uuid) do
    from(m in TemplateTaxonomy, where: m.type_uuid == ^type_uuid, select: m.template_uuid)
    |> repo().all()
    |> Enum.uniq()
  end

  # Recomputes the legacy mirror of each template from its memberships in
  # ACTIVE categories only (references to a soft-deleted group are cleared).
  # This keeps the mirror honest across category/type trash + restore: it never
  # points at a deleted category, and a multi-category template moves to its
  # next active category instead of vanishing from legacy single-category
  # readers. A template with no active membership left gets a nil mirror.
  defp recompute_mirrors([]), do: :ok

  defp recompute_mirrors(template_uuids) do
    Enum.each(template_uuids, fn template_uuid ->
      active =
        from(m in TemplateTaxonomy,
          join: c in Category,
          on: c.uuid == m.category_uuid,
          left_join: t in Type,
          on: t.uuid == m.type_uuid,
          where: m.template_uuid == ^template_uuid and c.status != "deleted",
          select: {m.category_uuid, m.type_uuid, t.status}
        )
        |> repo().all()
        |> Enum.map(fn {category_uuid, type_uuid, type_status} ->
          %{
            category_uuid: category_uuid,
            type_uuid: if(type_status == "deleted", do: nil, else: type_uuid)
          }
        end)

      mirror_primary_membership(template_uuid, active)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Default group order (part А — the canonical ANDI group set)
  # ---------------------------------------------------------------------------

  # The canonical order ANDI expects its template groups (Types) to appear in
  # (Hinnapakkumine before Tellimus, etc.). Positions 0..8 follow this order.
  @default_group_order ~w(
    Hinnapakkumine Eeltellimus Moodistamine Tellimus Leping
    Joonised Vastuvõtuakt Garantii Hooldusjuhend
  )

  @doc "Returns the canonical ANDI group names, in order."
  @spec default_group_order() :: [String.t()]
  def default_group_order, do: @default_group_order

  @doc """
  Seeds (idempotently) the canonical ANDI group set under `category_uuid`,
  positioned `0..8` in `default_group_order/0` order.

  - A missing canonical group is created at its canonical position.
  - An existing active group with a canonical name is repositioned (never
    duplicated).
  - Any other active groups under the category are pushed after the canonical
    block (positions continue from 9) so the canonical order is collision-free.

  Runs in one transaction and broadcasts a single `:type` change. This is the
  code seed for part А — call it per category (e.g. from Admin → Documents →
  Categories) instead of dragging the 9 groups into order by hand.
  """
  @spec ensure_default_group_order(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def ensure_default_group_order(category_uuid, opts \\ []) when is_binary(category_uuid) do
    result = repo().transaction(fn -> seed_default_groups(category_uuid) end)

    with {:ok, _} <- result do
      log_activity(%{
        action: "doc_taxonomy.category.default_groups_seeded",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "doc_category",
        resource_uuid: category_uuid,
        metadata: %{"count" => length(@default_group_order)}
      })

      broadcast(:type, nil)
      :ok
    end
  end

  # Transaction body for `ensure_default_group_order/2`: position the canonical
  # groups 0..8, then push any others after them.
  defp seed_default_groups(category_uuid) do
    now = DateTime.utc_now()
    existing = list_types_for_category(category_uuid)
    by_name = Map.new(existing, &{&1.name, &1})

    @default_group_order
    |> Enum.with_index()
    |> Enum.each(fn {name, index} ->
      upsert_canonical_group(category_uuid, by_name, name, index, now)
    end)

    reposition_extra_groups(existing, now)
  end

  # Non-canonical active groups keep their rows but move after the canonical
  # 0..8 block so the seeded order is collision-free.
  defp reposition_extra_groups(existing, now) do
    existing
    |> Enum.reject(&(&1.name in @default_group_order))
    |> Enum.with_index(length(@default_group_order))
    |> Enum.each(fn {type, index} ->
      from(t in Type, where: t.uuid == ^type.uuid)
      |> repo().update_all(set: [position: index, updated_at: now])
    end)
  end

  # Creates a canonical group at `index`, or repositions an existing one with
  # the same name. Rolls the seed transaction back on an invalid create.
  #
  # Inserts the Type directly (not via `create_type/2`) on purpose: this runs
  # inside `ensure_default_group_order/2`'s transaction, and `create_type/2`
  # would `broadcast/2` + `log_activity/1` from an uncommitted transaction. The
  # single post-commit broadcast is emitted by `ensure_default_group_order/2`.
  defp upsert_canonical_group(category_uuid, by_name, name, index, now) do
    case Map.get(by_name, name) do
      nil ->
        %Type{}
        |> Type.changeset(%{name: name, category_uuid: category_uuid, position: index})
        |> repo().insert()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} -> repo().rollback(changeset)
        end

      %Type{} = type ->
        from(t in Type, where: t.uuid == ^type.uuid)
        |> repo().update_all(set: [position: index, updated_at: now])
    end
  end

  # ---------------------------------------------------------------------------
  # Picker helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns a list of `{category, [types]}` tuples for all active categories,
  ordered by position. Types within each category are ordered by position.

  Useful for building grouped pickers in LiveViews.
  """
  @spec list_category_tree() :: [{Category.t(), [Type.t()]}]
  def list_category_tree do
    categories =
      from(c in Category,
        where: c.status != "deleted",
        order_by: [asc: c.position, asc: c.name]
      )
      |> repo().all()

    case categories do
      [] ->
        []

      cats ->
        cat_uuids = Enum.map(cats, & &1.uuid)

        types_by_category =
          from(t in Type,
            where: t.category_uuid in ^cat_uuids and t.status != "deleted",
            order_by: [asc: t.position, asc: t.name]
          )
          |> repo().all()
          |> Enum.group_by(& &1.category_uuid)

        Enum.map(cats, fn cat ->
          {cat, Map.get(types_by_category, cat.uuid, [])}
        end)
    end
  end

  @doc """
  Returns `[{label, value}]` for all active categories, ordered by position,
  preceded by a `{"No category", nil}` empty option.

  Suitable for `options_for_select/2`. The empty option lets users clear the
  FK (which is nullable).

  `locale` selects the translated label via `localized_name/2`; omit (or
  pass `nil`) to fall back to the denormalized `name` column.

  Drop-in replacement for the hard-coded `category_options/0` in
  `documents_live.ex`.
  """
  @spec category_options(String.t() | nil) :: [{String.t(), Ecto.UUID.t() | nil}]
  def category_options(locale \\ nil) do
    entries = list_categories() |> Enum.map(fn c -> {localized_name(c, locale), c.uuid} end)
    [{gettext("No category"), nil} | entries]
  end

  @doc """
  Returns `[{label, value}]` for all active types within a category, ordered
  by position, preceded by a `{"No type", nil}` empty option.

  Pass `nil` as `category_uuid` (or when no category is selected) to get
  only the empty option. `locale` selects the translated label via
  `localized_name/2`.

  Suitable for `options_for_select/2`.
  """
  @spec type_options(Ecto.UUID.t() | nil, String.t() | nil) :: [{String.t(), Ecto.UUID.t() | nil}]
  def type_options(category_uuid, locale \\ nil)
  def type_options(nil, _locale), do: [{gettext("No type"), nil}]

  def type_options(category_uuid, locale) when is_binary(category_uuid) do
    entries =
      list_types_for_category(category_uuid)
      |> Enum.map(fn t -> {localized_name(t, locale), t.uuid} end)

    [{gettext("No type"), nil} | entries]
  end

  @doc """
  Returns the display name of a `Category` or `Type` record translated into
  `locale`, reading overrides from the multilang `data` JSONB via
  `PhoenixKit.Utils.Multilang.get_language_data/2`.

  Mirrors `PhoenixKitCatalogue.Catalogue.get_translation/2` — falls back to
  the primary-language value, then to the denormalized `name` column.
  Returns `record.name` unchanged when `locale` is `nil` or no translation
  data exists yet.
  """
  @spec localized_name(Category.t() | Type.t() | map(), String.t() | nil) :: String.t()
  def localized_name(record, locale) do
    data = Map.get(record, :data) || %{}
    name = Map.get(record, :name)
    lang_data = Multilang.get_language_data(data, locale || "")

    case Map.get(lang_data, "_name") || Map.get(lang_data, "name") do
      translated when is_binary(translated) and translated != "" -> translated
      _ -> name
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Injects a default `:position`/`"position"` (matching the caller's key
  # style, since Ecto.Changeset.cast/3 rejects a params map with mixed atom
  # and string keys) unless the caller already supplied one explicitly.
  # Without this, every new category/type lands at the schema default of 0
  # and ties for first place with whatever else is already there, forcing
  # an immediate manual drag to move it to the end of the list.
  defp put_default_position(attrs, position_fun) do
    cond do
      Map.has_key?(attrs, :position) or Map.has_key?(attrs, "position") ->
        attrs

      Enum.any?(attrs, fn {key, _value} -> is_atom(key) end) ->
        Map.put(attrs, :position, position_fun.())

      true ->
        Map.put(attrs, "position", position_fun.())
    end
  end

  # Read-then-insert with no transaction or unique constraint: two
  # concurrent creates can tie for the same position. Accepted — position
  # has no uniqueness requirement, ties order by name (as they always did
  # under the old default-0 behaviour) and one drag fixes them; a
  # serialized insert isn't worth the locking here.
  defp next_category_position do
    Category
    |> apply_status_filter([])
    |> select([c], max(c.position))
    |> repo().one()
    |> next_position()
  end

  defp next_type_position(category_uuid) do
    from(t in Type, where: t.category_uuid == ^category_uuid)
    |> apply_status_filter([])
    |> select([t], max(t.position))
    |> repo().one()
    |> next_position()
  end

  defp next_position(nil), do: 0
  defp next_position(max), do: max + 1

  # Reads the most recent trash activity log entry for the given level and uuid
  # and returns the type/template uuids that were cascade-trashed at the time as
  # `%{types: [...], templates: [...]}`. Both lists are empty when no matching
  # entry is found.
  defp fetch_cascade_uuids(level, resource_uuid) do
    action =
      case level do
        :category -> "doc_taxonomy.category.trashed"
        :type -> "doc_taxonomy.type.trashed"
      end

    entry =
      from(e in PhoenixKit.Activity.Entry,
        where: e.action == ^action and e.resource_uuid == ^resource_uuid,
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> repo().one()

    metadata =
      case entry do
        %{metadata: %{} = metadata} -> metadata
        _ -> %{}
      end

    %{
      types: uuid_list(metadata, "cascade_type_uuids"),
      templates: uuid_list(metadata, "cascade_template_uuids")
    }
  end

  defp uuid_list(metadata, key) do
    case Map.get(metadata, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
