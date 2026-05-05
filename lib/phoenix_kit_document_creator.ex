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

  # No `migration_module/0` override — migrations are handled by
  # PhoenixKit core (V86 + V94 create the doc tables; this module owns
  # no migrations of its own). The `PhoenixKit.Module` behaviour treats
  # the callback as optional, so omitting it is the canonical pattern.

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Document Creator",
      icon: "hero-document-text",
      description: "Visual template design and PDF generation"
    }
  end

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_document_creator]

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
        permission: module_key(),
        match: :exact,
        live_view: {PhoenixKitDocumentCreator.Web.GoogleOAuthSettingsLive, :index}
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
        live_view: {PhoenixKitDocumentCreator.Web.DocumentsLive, :documents}
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
        live_view: {PhoenixKitDocumentCreator.Web.DocumentsLive, :documents}
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
        live_view: {PhoenixKitDocumentCreator.Web.DocumentsLive, :templates}
      }
    ]
  end

  # ===========================================================================
  # Legacy migration
  # ===========================================================================

  @legacy_oauth_settings_key "document_creator_google_oauth"
  @new_integration_provider "google"
  @new_integration_name "default"

  # Implements the optional `migrate_legacy/0` callback added in core
  # V107+. Hex `~> 1.7` doesn't declare it on the `PhoenixKit.Module`
  # behaviour, so `@impl PhoenixKit.Module` would warn — keep this as
  # a plain function until the floor version is bumped. The orchestrator
  # in `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`
  # dispatches by `function_exported?/3` regardless of the annotation.
  def migrate_legacy do
    creds_result = migrate_legacy_oauth_credentials()
    refs_result = migrate_legacy_connection_references()

    {:ok,
     %{
       credentials_migration: creds_result,
       reference_migration: refs_result
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
        "[DocumentCreator] OAuth credentials migration raised: #{Exception.message(e)}"
      )

      {:error, e}
  end

  # Prefer the uuid-strict `find_uuid_by_provider_name/1` (core 1.7.105+)
  # so the check matches the same lookup shape we use elsewhere
  # (`migrate_legacy_connection_references/0`, the consumer pattern in
  # AGENTS.md). On older cores that pre-date the helper, fall back to
  # the legacy `provider:name` string lookup against `get_integration/1`'s
  # dual-input read shim. The fallback can be deleted once
  # `phoenix_kit ~> 1.7.105` is the floor in `mix.exs` (also tracked in
  # dev_docs/migration_cleanup.md).
  defp already_migrated? do
    storage_key = "#{@new_integration_provider}:#{@new_integration_name}"

    if function_exported?(Integrations, :find_uuid_by_provider_name, 1) do
      # `apply/3` is deliberate: cores that pre-date the helper would
      # otherwise emit an "undefined function" warning at compile time
      # even though the `function_exported?/3` guard makes the call
      # safe at runtime. Drop the `apply/3` once `~> 1.7.105` is the
      # floor in `mix.exs`.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(Integrations, :find_uuid_by_provider_name, [storage_key]) |> is_binary()
    else
      case Integrations.get_integration(storage_key) do
        {:ok, _} -> true
        _ -> false
      end
    end
  end

  defp do_migrate_oauth_credentials(legacy_data) do
    integration_data = build_integration_data(legacy_data)
    integration_key = "#{@new_integration_provider}:#{@new_integration_name}"

    # Two-step write under core's strict-UUID Integrations API: create
    # the row via `add_connection/3` (the only legitimate place to
    # construct a new `integration:{provider}:{name}` storage key),
    # then save the migrated credentials against the returned uuid.
    with {:ok, %{uuid: uuid}} <-
           ensure_connection(@new_integration_provider, @new_integration_name),
         {:ok, _saved} <- Integrations.save_setup(uuid, integration_data) do
      migrate_legacy_folders(legacy_data)
      clear_legacy_oauth_key()

      log_migration_activity(:credentials_migrated, %{
        legacy_key: @legacy_oauth_settings_key,
        new_key: "integration:#{integration_key}",
        integration_uuid: uuid
      })

      Logger.info(
        "[DocumentCreator] Migrated legacy '#{@legacy_oauth_settings_key}' → 'integration:#{integration_key}'"
      )

      :migrated
    else
      {:error, reason} ->
        Logger.warning(
          "[DocumentCreator] OAuth credentials migration save failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp ensure_connection(provider, name) do
    case Integrations.add_connection(provider, name) do
      {:ok, %{uuid: _} = result} ->
        {:ok, result}

      {:error, :already_exists} ->
        resolve_existing_connection_uuid(provider, name)

      error ->
        error
    end
  end

  # Cross-version compat for the `:already_exists` resolve step.
  #
  # `find_uuid_by_provider_name/1` is the cleaner V107 primitive but
  # doesn't exist in Hex `~> 1.7`. Without the `function_exported?/3`
  # gate, dialyzer / `mix precommit` flags it as a missing call.
  # When the floor version is bumped past V107 the gate can be
  # removed and the call inlined.
  defp resolve_existing_connection_uuid(provider, name) do
    if function_exported?(Integrations, :find_uuid_by_provider_name, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Integrations, :find_uuid_by_provider_name, [{provider, name}]) do
        {:ok, uuid} -> {:ok, %{uuid: uuid}}
        error -> error
      end
    else
      # Pre-V107 fallback — scan provider's connections by name.
      case Integrations.list_connections(provider) |> Enum.find(&(&1.name == name)) do
        %{uuid: uuid} -> {:ok, %{uuid: uuid}}
        _ -> {:error, :not_found}
      end
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

  # After the credentials are migrated into a `PhoenixKit.Integrations`
  # row (which encrypts secrets at rest), the original
  # `document_creator_google_oauth` settings row still holds plaintext
  # `client_secret` / `access_token` / `refresh_token`. `already_migrated?/0`
  # stops re-migration on subsequent boots, so without this cleanup the
  # plaintext copies would persist in `phoenix_kit_settings` indefinitely.
  # Overwrite with `%{}` to keep the row but drop the secrets. Failure
  # here doesn't roll back the migration — it's a best-effort secrets
  # wipe; ops can always remove the row by hand.
  defp clear_legacy_oauth_key do
    Settings.update_json_setting_with_module(
      @legacy_oauth_settings_key,
      %{},
      module_key()
    )

    :ok
  rescue
    e ->
      Logger.warning(
        "[DocumentCreator] Failed to clear legacy OAuth key after migration — " <>
          "plaintext secrets may remain in '#{@legacy_oauth_settings_key}'. " <>
          "exception=#{inspect(e.__struct__)}"
      )

      :ok
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
    end
  rescue
    e ->
      Logger.warning(
        "[DocumentCreator] Failed to move legacy folder config: #{Exception.message(e)}"
      )
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

  # `find_uuid_by_provider_name/1` is the cleaner core API but only
  # exists in newer phoenix_kit versions. Use `list_connections/1`
  # (long-stable) so this works against any phoenix_kit dep this
  # module's mix.exs allows.
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

  defp log_migration_activity(action_atom, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "integration.legacy_migrated",
        module: module_key(),
        mode: "auto",
        resource_type: "integration",
        metadata:
          Map.merge(metadata, %{
            "migration_kind" => Atom.to_string(action_atom),
            "actor_role" => "system"
          })
      })
    end

    :ok
  rescue
    e ->
      # Activity logging failures must NEVER crash the migration
      # path — the orchestrator already caught any earlier exception
      # by the time we get here, and we don't want a missing
      # activities table (host hasn't run core's migration yet) to
      # turn a successful credentials migration into a boot failure.
      # But silently returning :ok means an ops team can't tell why
      # their audit feed is empty. Log the exception type before
      # swallowing.
      Logger.warning(fn ->
        "[DocumentCreator] activity log failed during legacy migration: " <>
          "kind=#{action_atom}, exception=#{inspect(e.__struct__)}"
      end)

      :ok
  end
end
