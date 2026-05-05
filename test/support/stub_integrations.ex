defmodule PhoenixKitDocumentCreator.Test.StubIntegrations do
  @moduledoc """
  Test stub for `PhoenixKit.Integrations`. Implements the three call
  sites used by `GoogleDocsClient`: `get_integration/1`,
  `get_credentials/1`, and `authenticated_request/4`.

  Tests opt in via:

      Application.put_env(
        :phoenix_kit_document_creator,
        :integrations_backend,
        PhoenixKitDocumentCreator.Test.StubIntegrations
      )

  And install per-test responses via `connected!/1` and `stub_request/3`.
  The dispatcher keeps test setup small — most LV mount tests just
  need `connected!()` and a couple of canned responses for the Drive
  endpoints they hit.

  ## Concurrency contract — `async: false` REQUIRED

  Test files using this stub **must** declare `use ExUnit.Case, async: false`
  (or `use DataCase, async: false`). The stub is backed by a single
  named ETS table (`:pkdc_stub_integrations`); the named table is
  required because the LiveView process must be able to read state
  set by the test process, and process-dictionary or per-pid storage
  doesn't cross the test→LV process boundary. Two concurrent tests
  writing to the same table would race.

  `claim!/0` runs at the top of `connected!/1` / `stub_request/3` /
  `seed_connection!/2` and registers the calling pid as the table
  owner; subsequent calls from a different pid raise loudly with a
  `:concurrent_stub_use` exit so the violation is impossible to
  miss. Use `release!/0` from `on_exit` to make the table available
  for the next test.

  Production behaviour is unchanged — the resolver in
  `GoogleDocsClient.integrations_backend/0` defaults to
  `PhoenixKit.Integrations` when the config is absent.
  """

  @ets_table :pkdc_stub_integrations

  @typedoc "Canned response for a single HTTP call: `%Req.Response{}` or `{:error, term()}`."
  @type canned :: {:ok, map()} | {:error, term()}

  @doc "Mark the stub as 'connected' — `get_integration/1` returns `{:ok, _}`."
  @spec connected!(String.t()) :: :ok
  def connected!(email \\ "test@example.com") do
    claim!()
    :ets.insert(@ets_table, {:connected_email, email})
    seed_active_integration_setting()
    :ok
  end

  @doc """
  Claim ownership of the stub for the calling pid. Raises if another
  test (different pid) is already holding it. Called automatically
  by `connected!/1`, `stub_request/3`, and `seed_connection!/2`.
  """
  @spec claim!() :: :ok
  def claim! do
    ensure_table()
    me = self()

    case :ets.lookup(@ets_table, :owner_pid) do
      [] ->
        :ets.insert(@ets_table, {:owner_pid, me})
        :ok

      [{:owner_pid, ^me}] ->
        :ok

      [{:owner_pid, other}] ->
        if Process.alive?(other) do
          raise """
          PhoenixKitDocumentCreator.Test.StubIntegrations is already in use by \
          pid=#{inspect(other)}; pid=#{inspect(me)} attempted concurrent access. \
          The stub is backed by a single named ETS table; tests using it must \
          declare `async: false`.
          """
        else
          :ets.insert(@ets_table, {:owner_pid, me})
          :ok
        end
    end
  end

  @doc """
  Release ownership of the stub. Call from `on_exit/2` so the next
  test can claim it. Also clears all per-test state.
  """
  @spec release!() :: :ok
  def release! do
    case :ets.info(@ets_table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@ets_table)
    end

    :ok
  end

  # Mirror the stub's "connected" state into the document_creator
  # settings row that `GoogleDocsClient.active_integration_uuid/0`
  # reads. Pre-Phase 3b the active provider key fell back to the
  # literal `"google"` when nothing was stored; post-Phase 3b
  # `active_integration_uuid/0` returns `nil` and short-circuits the
  # downstream calls. Seed a sentinel uuid here so existing tests
  # that only call `connected!/1` get the same dispatch behavior
  # they had before.
  defp seed_active_integration_setting do
    fake_uuid = "019d0000-0000-7000-8000-0000000000ff"

    PhoenixKit.Settings.update_json_setting_with_module(
      "document_creator_settings",
      %{"google_connection" => fake_uuid},
      "document_creator"
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc "Mark the stub as disconnected (default state)."
  @spec disconnected!() :: :ok
  def disconnected! do
    claim!()
    :ets.delete(@ets_table, :connected_email)
    :ok
  end

  @doc """
  Register a canned response for an HTTP call matched by `{method, url_pattern}`.

  `url_pattern` is a substring or regex matched against the request URL.
  Falls back to `{:error, :unstubbed_request}` if no rule matches at
  call time — tests should fail loudly when a code path makes an
  unexpected outbound request.
  """
  @spec stub_request(atom(), String.t() | Regex.t(), canned()) :: :ok
  def stub_request(method, url_pattern, response)
      when is_atom(method) and (is_binary(url_pattern) or is_struct(url_pattern, Regex)) do
    claim!()
    rules = rules()
    :ets.insert(@ets_table, {:rules, rules ++ [{method, url_pattern, response}]})
    :ok
  end

  @doc "Reset all stub state. Equivalent to `release!/0` — kept for back-compat."
  @spec reset!() :: :ok
  def reset!, do: release!()

  # ── PhoenixKit.Integrations contract ────────────────────────────────

  @spec get_integration(String.t()) :: {:ok, map()} | {:error, atom()}
  def get_integration(provider_key) do
    # If the caller asked for a specific `provider:name` and a matching
    # seeded connection exists, return its data shape (matches the real
    # `PhoenixKit.Integrations.get_integration/1` response — the JSONB
    # row's blob, including `"name"` / `"provider"` keys). Otherwise
    # fall back to the connected-email shape for legacy "any" lookups.
    case lookup_connection_by_key(provider_key) do
      %{data: data} = _conn ->
        {:ok, data}

      nil ->
        case connected_email() do
          nil ->
            {:error, :not_configured}

          email ->
            {:ok,
             %{
               "external_account_id" => email,
               "metadata" => %{"connected_email" => email}
             }}
        end
    end
  end

  defp lookup_connection_by_key(key) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [provider, name] when name != "" ->
        list_connections(provider) |> Enum.find(fn c -> c.name == name end)

      _ ->
        nil
    end
  end

  defp lookup_connection_by_key(_), do: nil

  @spec get_credentials(String.t()) :: {:ok, map()} | {:error, atom()}
  def get_credentials(_provider_key) do
    case connected_email() do
      nil -> {:error, :not_configured}
      _ -> {:ok, %{access_token: "stub-token", refresh_token: "stub-refresh"}}
    end
  end

  @doc """
  Stub for `PhoenixKit.Integrations.list_connections/1`. Returns an
  empty list by default; tests opt in via `seed_connection!/2`.
  """
  @spec list_connections(String.t()) :: [%{uuid: String.t(), name: String.t(), data: map()}]
  def list_connections(provider_key) do
    ensure_table()

    case :ets.lookup(@ets_table, {:connections, provider_key}) do
      [{_key, list}] -> list
      [] -> []
    end
  end

  @doc """
  Adds a fake connection to the stub's `list_connections/1` response
  for `provider_key`. Use to test multi-account flows or the
  `migrate_legacy_connection/1` helper that scans for a target row.
  """
  @spec seed_connection!(String.t(), %{uuid: String.t(), name: String.t(), data: map()}) :: :ok
  def seed_connection!(provider_key, conn) do
    claim!()

    existing =
      case :ets.lookup(@ets_table, {:connections, provider_key}) do
        [{_, list}] -> list
        [] -> []
      end

    :ets.insert(@ets_table, {{:connections, provider_key}, existing ++ [conn]})
    :ok
  end

  @spec authenticated_request(String.t(), atom(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def authenticated_request(_provider_key, method, url, _opts) do
    matching =
      Enum.find(rules(), fn
        {^method, %Regex{} = re, _} -> Regex.match?(re, url)
        {^method, pattern, _} when is_binary(pattern) -> String.contains?(url, pattern)
        _ -> false
      end)

    case matching do
      {_, _, response} -> response
      nil -> {:error, {:unstubbed_request, method, url}}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────

  # Lazily create the ETS table on first use. `:public` so any process
  # (the test process AND the LiveView process) can read/write. `:set`
  # because we use known keys (`:connected_email`, `:rules`).
  defp ensure_table do
    case :ets.info(@ets_table) do
      :undefined -> :ets.new(@ets_table, [:set, :public, :named_table])
      _ -> :ok
    end
  end

  defp connected_email do
    ensure_table()

    case :ets.lookup(@ets_table, :connected_email) do
      [{:connected_email, email}] -> email
      [] -> nil
    end
  end

  defp rules do
    ensure_table()

    case :ets.lookup(@ets_table, :rules) do
      [{:rules, list}] -> list
      [] -> []
    end
  end
end
