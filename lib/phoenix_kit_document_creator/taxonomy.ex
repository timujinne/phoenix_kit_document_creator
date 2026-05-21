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

  alias PhoenixKitDocumentCreator.Schemas.Category
  alias PhoenixKitDocumentCreator.Schemas.Template
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
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
    end

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

    * `:description`, `:position` (default 0), `:status` (default `"active"`),
      `:data`
  """
  @spec create_category(map(), keyword()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t(Category.t())}
  def create_category(attrs, opts \\ []) do
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
        template_uuids =
          from(tmpl in Template,
            where:
              (tmpl.category_uuid == ^category.uuid or
                 tmpl.type_uuid in ^type_uuids) and
                tmpl.status != "trashed",
            select: tmpl.uuid
          )
          |> repo().all()

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

        category
        |> Category.changeset(%{status: "active"})
        |> repo().update!()
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

  @doc "Fetches a type by UUID. Returns `nil` if not found."
  @spec get_type(Ecto.UUID.t()) :: Type.t() | nil
  def get_type(uuid), do: repo().get(Type, uuid)

  @doc "Fetches a type by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_type!(Ecto.UUID.t()) :: Type.t()
  def get_type!(uuid), do: repo().get!(Type, uuid)

  # ---------------------------------------------------------------------------
  # Type — write
  # ---------------------------------------------------------------------------

  @doc """
  Creates a type.

  ## Required attributes

    * `:name` — type name (1-255 chars)
    * `:category_uuid` — parent category

  ## Optional attributes

    * `:description`, `:position`, `:status`, `:data`
  """
  @spec create_type(map(), keyword()) ::
          {:ok, Type.t()} | {:error, Ecto.Changeset.t(Type.t())}
  def create_type(attrs, opts \\ []) do
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

        template_uuids =
          from(tmpl in Template,
            where: tmpl.type_uuid == ^type.uuid and tmpl.status != "trashed",
            select: tmpl.uuid
          )
          |> repo().all()

        unless template_uuids == [] do
          from(tmpl in Template, where: tmpl.uuid in ^template_uuids)
          |> repo().update_all(set: [status: "trashed", updated_at: now])
        end

        updated =
          type
          |> Type.changeset(%{status: "deleted"})
          |> repo().update!()

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

        type
        |> Type.changeset(%{status: "active"})
        |> repo().update!()
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

  Drop-in replacement for the hard-coded `category_options/0` in
  `documents_live.ex`.
  """
  @spec category_options() :: [{String.t(), Ecto.UUID.t() | nil}]
  def category_options do
    entries = list_categories() |> Enum.map(fn c -> {c.name, c.uuid} end)
    [{gettext("No category"), nil} | entries]
  end

  @doc """
  Returns `[{label, value}]` for all active types within a category, ordered
  by position, preceded by a `{"No type", nil}` empty option.

  Pass `nil` as `category_uuid` (or when no category is selected) to get
  only the empty option.

  Suitable for `options_for_select/2`.
  """
  @spec type_options(Ecto.UUID.t() | nil) :: [{String.t(), Ecto.UUID.t() | nil}]
  def type_options(nil), do: [{gettext("No type"), nil}]

  def type_options(category_uuid) when is_binary(category_uuid) do
    entries = list_types_for_category(category_uuid) |> Enum.map(fn t -> {t.name, t.uuid} end)
    [{gettext("No type"), nil} | entries]
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Reads the most recent trash activity log entry for the given level and uuid
  # and returns the type/template uuids that were cascade-trashed at the time as
  # `%{types: [...], templates: [...]}`. Both lists are empty when no matching
  # entry is found or the Activity schema isn't loaded.
  defp fetch_cascade_uuids(level, resource_uuid) do
    action =
      case level do
        :category -> "doc_taxonomy.category.trashed"
        :type -> "doc_taxonomy.type.trashed"
      end

    if Code.ensure_loaded?(PhoenixKit.Activity.Entry) do
      fetch_cascade_uuids_from_activity(action, resource_uuid)
    else
      %{types: [], templates: []}
    end
  end

  defp fetch_cascade_uuids_from_activity(action, resource_uuid) do
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
