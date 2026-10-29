defmodule PhoenixKitDocumentCreator do
  @moduledoc """
  Document Creator module for PhoenixKit.

  Document template design and PDF generation via Google Docs API.

  Templates, documents, and headers/footers are created and edited as
  Google Docs, embedded in the admin UI via iframe. Variables use
  `{{ placeholder }}` syntax and are substituted via the Google Docs
  `replaceAllText` API. PDF export uses the Google Drive export endpoint.

  ## Installation

  Add to your parent app's `mix.exs`:

      {:phoenix_kit_document_creator, path: "../phoenix_kit_document_creator"}

  Then `mix deps.get`. The module auto-discovers via beam scanning.
  Enable it in Admin > Modules.

  ## Google Docs Setup

  Configure the Google Docs integration in Admin > Settings > Document Creator.
  You need a Google Cloud project with Docs API and Drive API enabled,
  and an OAuth 2.0 Client ID (Web application type).
  """

  use PhoenixKit.Module

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Integrations
  alias PhoenixKit.Settings
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def module_key, do: "document_creator"

  @impl PhoenixKit.Module
  def module_name, do: "Document Creator"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("document_creator_enabled", false)
  rescue
    _ -> false
  catch
    # During test sandbox shutdown the pool checkout exits with
    # `"owner #PID<...> exited"` — `rescue` doesn't catch :exit signals.
    # Without this clause, a 1-in-N suite run flakes on the next test
    # that calls `enabled?/0` from a process the sandbox no longer owns.
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module("document_creator_enabled", true, module_key())
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("document_creator_enabled", false, module_key())
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  # Derive at compile time from mix.exs so the runtime function can't
  # drift from the declared package version. The `version_test` callback
  # check pins this in `test/integration/module_callbacks_test.exs`.
  @version Mix.Project.config()[:version]

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  # Module-owned migration chain adopted (the decentralization protocol;
  # projects is the reference impl). Core still CREATES the doc tables
  # (V86 + V94); this chain only iterates on them — V1 adds
  # `project_uuid` for the projects hub's Documents tab.
  def migration_module, do: PhoenixKitDocumentCreator.Migrations.Schema

  @doc """
  The manifest of this module's tables, for `mix phoenix_kit.repair` and
  `mix phoenix_kit.doctor`; see `PhoenixKitDocumentCreator.ExpectedSchema`.
  """
  @impl PhoenixKit.Module
  def expected_schema, do: PhoenixKitDocumentCreator.ExpectedSchema

  # Project-extension catalog entry for the `phoenix_kit_projects` hub —
  # duck-typed contract (no dependency on that package, no `@impl`).
  # Linkage is PER-DOCUMENT (documents.project_uuid, V1 of this module's
  # own migration chain), not config-based: a project holds many docs.
  def phoenix_kit_project_extensions do
    [
      %{
        key: "document_creator_docs",
        name: "Documents",
        description: "Link Document Creator documents to this project",
        icon: "hero-document-text",
        module_key: "document_creator",
        default_enabled: false,
        tabs: [
          %{
            key: "documents",
            label: "Documents",
            icon: "hero-document-text",
            lv: PhoenixKitDocumentCreator.Web.ProjectDocumentsLive
          }
        ],
        permission_actions: [:view, :edit_tasks]
      }
    ]
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Document Creator",
      icon: "hero-document-text",
      description: "Visual template design and PDF generation",
      sub_permissions: [
        # The settings page repoints the module at a Google integration,
        # browses that account's Drive and moves the managed folders — more
        # than the everyday key should carry. `migrate_legacy/0` grants it
        # once to every role that held the base key before it existed.
        %{
          key: "settings",
          label: "Change Document Creator settings",
          description:
            "Choose the Google account the module uses, browse its Drive and change the managed folders"
        }
      ]
    }
  end

  @doc """
  The composed key of the settings sub-permission, for `Scope.can?/2`.
  Gates `Web.GoogleOAuthSettingsLive` at mount and on every event.
  """
  @spec settings_permission() :: String.t()
  def settings_permission, do: module_key() <> ".settings"

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_document_creator]

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitDocumentCreator.Web.Routes

  @impl PhoenixKit.Module
  def required_integrations, do: ["google"]

  @impl PhoenixKit.Module
  def children, do: []

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      %Tab{
        id: :admin_settings_document_creator,
        label: "Document Creator",
        icon: "hero-document-text",
        path: "document-creator",
        priority: 930,
        level: :admin,
        parent: :admin_settings,
        permission: settings_permission(),
        match: :exact,
        live_view: {PhoenixKitDocumentCreator.Web.GoogleOAuthSettingsLive, :index},
        gettext_backend: PhoenixKitDocumentCreator.Gettext,
        gettext_domain: "default"
      }
    ]
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    base_tabs()
  end

  defp base_tabs do
    [
      %Tab{
        id: :admin_document_creator,
        label: "Document Creator",
        icon: "hero-document-text",
        path: "document-creator",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true,
        live_view: {PhoenixKitDocumentCreator.Web.DocumentsLive, :documents},
        gettext_backend: PhoenixKitDocumentCreator.Gettext,
        gettext_domain: "default"
      },
      %Tab{
        id: :admin_document_creator_documents,
        label: "Documents",
        icon: "hero-document-duplicate",
        path: "document-creator/documents",
        priority: 648,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        match: :prefix,
        live_view: {PhoenixKitDocumentCreator.Web.DocumentsLive, :documents},
        gettext_backend: PhoenixKitDocumentCreator.Gettext,
        gettext_domain: "default"
      },
      %Tab{
        id: :admin_document_creator_templates,
        label: "Templates",
        icon: "hero-document-text",
        path: "document-creator/templates",
        priority: 649,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        match: :prefix,
        live_view: {PhoenixKitDocumentCreator.Web.DocumentsLive, :templates},
        gettext_backend: PhoenixKitDocumentCreator.Gettext,
        gettext_domain: "default"
      },
      %Tab{
        id: :admin_document_creator_categories,
        label: "Categories",
        icon: "hero-folder",
        path: "document-creator/categories",
        priority: 651,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        match: :prefix,
        live_view: {PhoenixKitDocumentCreator.Web.CategoriesLive, :index},
        gettext_backend: PhoenixKitDocumentCreator.Gettext,
        gettext_domain: "default"
      }
    ]
  end

  # ===========================================================================
  # Legacy migration
  # ===========================================================================

  @legacy_oauth_settings_key "document_creator_google_oauth"
  @new_integration_provider "google"
  @new_integration_name "default"

  # Runs at host boot via `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`.
  @impl PhoenixKit.Module
  def migrate_legacy do
    creds_result = migrate_legacy_oauth_credentials()
    refs_result = migrate_legacy_connection_references()
    settings_result = backfill_settings_permission()

    {:ok,
     %{
       credentials_migration: creds_result,
       reference_migration: refs_result,
       settings_permission_backfill: settings_result
     }}
  rescue
    e ->
      Logger.warning("[DocumentCreator] migrate_legacy/0 raised: #{Exception.message(e)}")

      {:error, e}
  end

  # Migration (1): pre-Integrations OAuth tokens stored under
  # `document_creator_google_oauth` → new `integration:google:default`
  # row managed by PhoenixKit.Integrations. Was previously in core's
  # `Integrations.run_legacy_migrations/0` (with hardcoded `@legacy_keys`);
  # moved here because the data shape is doc_creator-specific.
  defp migrate_legacy_oauth_credentials do
    legacy_data = Settings.get_json_setting(@legacy_oauth_settings_key, nil)

    cond do
      not is_map(legacy_data) or map_size(legacy_data) == 0 ->
        :no_legacy_data

      already_migrated?() ->
        :already_migrated

      true ->
        do_migrate_oauth_credentials(legacy_data)
    end
  rescue
    e ->
      Logger.warning(
        "[DocumentCreator] OAuth credentials migration raised: exception=#{inspect(e.__struct__)}"
      )

      {:error, e}
  end

  # A row can exist before any credentials were saved (manual creation or an
  # interrupted migration). Preserve even partially configured connections.
  defp already_migrated? do
    case Integrations.find_uuid_by_provider_name(
           {@new_integration_provider, @new_integration_name}
         ) do
      {:ok, uuid} ->
        # Inspect presence in storage, so a temporarily undecryptable secret
        # is still protected from being overwritten by the legacy value.
        data = Settings.get_json_setting_by_uuid(uuid, %{})

        Enum.any?(
          ~w(client_id client_secret access_token refresh_token),
          &(data[&1] not in [nil, ""])
        )

      {:error, :not_found} ->
        false
    end
  end

  defp do_migrate_oauth_credentials(legacy_data) do
    integration_data = build_integration_data(legacy_data)
    integration_key = "#{@new_integration_provider}:#{@new_integration_name}"

    # Commit the connection, folders and plaintext cleanup together. Otherwise
    # a failed write leaves an apparently migrated row that later boots skip,
    # or clears the only copy of folder settings that were never saved.
    repo = PhoenixKit.RepoHelper.repo()

    result =
      repo.transaction(fn ->
        with {:ok, %{uuid: uuid}} <-
               ensure_connection(@new_integration_provider, @new_integration_name),
             {:ok, _saved} <- Integrations.save_setup(uuid, integration_data),
             {:ok, _folders} <- migrate_legacy_folders(legacy_data),
             {:ok, _cleared} <- clear_legacy_oauth_key() do
          uuid
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, uuid} ->
        log_migration_activity(:credentials_migrated, %{
          legacy_key: @legacy_oauth_settings_key,
          new_key: "integration:#{integration_key}",
          integration_uuid: uuid
        })

        Logger.info(
          "[DocumentCreator] Migrated legacy '#{@legacy_oauth_settings_key}' → 'integration:#{integration_key}'"
        )

        :migrated

      {:error, reason} ->
        Logger.warning("[DocumentCreator] OAuth credentials migration save failed")

        {:error, reason}
    end
  end

  defp ensure_connection(provider, name) do
    # Core allows duplicate names; add_connection/3 does not return
    # :already_exists. Reuse an empty row so existing UUID references survive.
    case Integrations.find_uuid_by_provider_name({provider, name}) do
      {:ok, uuid} -> {:ok, %{uuid: uuid}}
      {:error, :not_found} -> Integrations.add_connection(provider, name)
      error -> error
    end
  end

  defp build_integration_data(legacy_data) do
    base = %{
      "provider" => @new_integration_provider,
      "auth_type" => "oauth2",
      "client_id" => legacy_data["client_id"],
      "client_secret" => legacy_data["client_secret"],
      "access_token" => legacy_data["access_token"],
      "refresh_token" => legacy_data["refresh_token"],
      "token_type" => legacy_data["token_type"] || "Bearer",
      "token_obtained_at" => legacy_data["token_obtained_at"],
      "status" => derive_status(legacy_data),
      "external_account_id" => legacy_data["connected_email"],
      "metadata" => %{
        "connected_email" => legacy_data["connected_email"]
      }
    }

    base
    |> maybe_put_expires_at(legacy_data)
    |> maybe_put_connected_at(legacy_data)
  end

  defp derive_status(%{"access_token" => token}) when is_binary(token) and token != "",
    do: "connected"

  defp derive_status(_), do: "disconnected"

  defp maybe_put_expires_at(data, legacy_data) do
    with expires_in when is_integer(expires_in) <- legacy_data["expires_in"],
         obtained_at when is_binary(obtained_at) <- legacy_data["token_obtained_at"],
         {:ok, dt, _} <- DateTime.from_iso8601(obtained_at) do
      Map.put(
        data,
        "expires_at",
        dt |> DateTime.add(expires_in, :second) |> DateTime.to_iso8601()
      )
    else
      _ -> data
    end
  end

  defp maybe_put_connected_at(%{"status" => "connected"} = data, legacy_data) do
    Map.put(
      data,
      "connected_at",
      legacy_data["token_obtained_at"] || DateTime.utc_now() |> DateTime.to_iso8601()
    )
  end

  defp maybe_put_connected_at(data, _legacy_data), do: data

  # Remove plaintext copies only in the transaction that saves their new home.
  defp clear_legacy_oauth_key do
    Settings.update_json_setting_with_module(
      @legacy_oauth_settings_key,
      %{},
      module_key()
    )
  end

  defp migrate_legacy_folders(legacy_data) do
    folder_fields = ~w(
      folder_path_templates folder_name_templates
      folder_path_documents folder_name_documents
      folder_path_deleted folder_name_deleted
      templates_folder_id documents_folder_id
      deleted_templates_folder_id deleted_documents_folder_id
    )

    folder_data = Map.take(legacy_data, folder_fields)

    if map_size(folder_data) > 0 do
      Settings.update_json_setting_with_module(
        "document_creator_folders",
        folder_data,
        module_key()
      )
    else
      {:ok, nil}
    end
  end

  # Migration (2): boot-time sweep that resolves any name-string
  # `document_creator_settings.google_connection` value to its
  # matching integration row's uuid. The same logic runs lazily on
  # first read via `GoogleDocsClient.active_integration_uuid/0` —
  # this boot pass just rewrites it eagerly so admins don't see a
  # delay on first page load.
  defp migrate_legacy_connection_references do
    case Settings.get_json_setting("document_creator_settings", %{}) do
      %{"google_connection" => value} when is_binary(value) and value != "" ->
        if GoogleDocsClient.uuid?(value) do
          :already_uuid
        else
          resolve_and_persist(value)
        end

      _ ->
        :no_reference_set
    end
  rescue
    e ->
      Logger.warning("[DocumentCreator] Reference migration raised: #{Exception.message(e)}")

      {:error, e}
  end

  defp resolve_and_persist(name_string) do
    case resolve_via_list_connections(name_string) do
      {:ok, uuid} ->
        rewrite_google_connection(uuid)

        log_migration_activity(:reference_migrated, %{
          old_value: name_string,
          new_uuid: uuid
        })

        :migrated

      {:error, reason} ->
        Logger.warning(
          "[DocumentCreator] Reference migration: cannot resolve '#{name_string}': #{inspect(reason)}"
        )

        # Audit the failure so the lazy and boot paths are symmetric:
        # both surface a `legacy_migrated` row with `migration_kind=
        # reference_migration_failed` when the resolver can't pin a
        # uuid. Without this row, ops have no audit trail of "we tried
        # to migrate at boot, it didn't resolve" — they only see the
        # resulting "not configured" state and the warning log line.
        log_migration_activity(:reference_migration_failed, %{
          old_value: name_string,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  # Resolves a legacy `provider` / `provider:name` string through
  # `list_connections/1`, defaulting the name to `"default"` (the one case
  # `find_uuid_by_provider_name/1` answers differently for a bare provider).
  defp resolve_via_list_connections(name_string) do
    {provider, name} =
      case String.split(name_string, ":", parts: 2) do
        [p, n] when n != "" -> {p, n}
        [p] -> {p, "default"}
      end

    Integrations.list_connections(provider)
    |> Enum.find(fn conn -> conn.name == name end)
    |> case do
      %{uuid: uuid} -> {:ok, uuid}
      _ -> {:error, :not_found}
    end
  rescue
    e ->
      # The lookup is the fallback path of the legacy reference sweep —
      # it runs at boot during `migrate_legacy/0` against whatever
      # state Settings is in. A raise here doesn't crash the boot
      # (the orchestrator catches it) but losing the exception type
      # makes ops debugging guesswork. Log with grep-able context
      # before swallowing. `Exception.message/1` is deliberately
      # excluded — some Ecto exception structs embed query bindings
      # that could leak provider strings into logs.
      Logger.warning(fn ->
        "[DocumentCreator] resolve_via_list_connections failed: " <>
          "exception=#{inspect(e.__struct__)}"
      end)

      {:error, :resolver_failed}
  end

  defp rewrite_google_connection(uuid) do
    current = Settings.get_json_setting("document_creator_settings", %{})
    updated = Map.put(current, "google_connection", uuid)

    Settings.update_json_setting_with_module(
      "document_creator_settings",
      updated,
      module_key()
    )
  end

  # Set once the settings sub-permission has been carried to the roles that
  # held the base key before it existed, so it never runs again and an
  # Owner's revoke sticks.
  @settings_backfill_key "document_creator_settings_backfilled"

  @doc false
  # Once: every role that already holds `document_creator` keeps the
  # settings page it could reach before `document_creator.settings` was
  # split out. A role created or granted the base key later gets the narrow
  # meaning. The flag is set only after every grant succeeded, so a failed
  # pass is retried on the next boot.
  def backfill_settings_permission do
    if Settings.get_setting(@settings_backfill_key) == "true" do
      :already_backfilled
    else
      do_backfill_settings_permission()
    end
  end

  defp do_backfill_settings_permission do
    alias PhoenixKit.Users.Permissions

    key = settings_permission()

    with {:ok, role_uuids} <- roles_lacking(module_key(), key),
         results = Enum.map(role_uuids, &Permissions.grant_permission(&1, key, nil)),
         true <- Enum.all?(results, &match?({:ok, _}, &1)),
         {:ok, _} <-
           Settings.update_setting_with_module(@settings_backfill_key, "true", module_key()) do
      :backfilled
    else
      {:error, :lookup_failed} = error ->
        Logger.warning(
          "[DocumentCreator] settings permission backfill could not read grants; retrying"
        )

        error

      _ ->
        Logger.warning(
          "[DocumentCreator] settings permission backfill incomplete; retrying next boot"
        )

        {:error, :grant_failed}
    end
  rescue
    e ->
      Logger.warning(
        "[DocumentCreator] settings permission backfill raised: exception=#{inspect(e.__struct__)}"
      )

      {:error, :backfill_failed}
  end

  # Roles holding `base` but not `key`, read with a query that RAISES on a
  # database error. Core's `Permissions.get_permissions_for_role/1` rescues
  # to `[]`, which would read as "nobody holds the base key" and set the
  # flag for good.
  @doc false
  def roles_lacking(base, key) do
    import Ecto.Query, only: [from: 2]

    repo = PhoenixKit.RepoHelper.repo()

    holders =
      from(rp in PhoenixKit.Users.RolePermission,
        where: rp.module_key == ^base,
        select: rp.role_uuid
      )
      |> repo.all()

    have =
      from(rp in PhoenixKit.Users.RolePermission,
        where: rp.module_key == ^key,
        select: rp.role_uuid
      )
      |> repo.all()
      |> MapSet.new()

    {:ok, holders |> Enum.uniq() |> Enum.reject(&MapSet.member?(have, &1))}
  rescue
    _ -> {:error, :lookup_failed}
  end

  # Core's log never raises: a missing activities table (host hasn't run
  # core's migration yet) is logged there and returned, so it can't turn a
  # successful credentials migration into a boot failure.
  defp log_migration_activity(action_atom, metadata) do
    PhoenixKit.Activity.log(module_key(), "integration.legacy_migrated",
      mode: "auto",
      resource_type: "integration",
      metadata:
        Map.merge(metadata, %{
          "migration_kind" => Atom.to_string(action_atom),
          "actor_role" => "system"
        })
    )

    :ok
  end
end
