defmodule PhoenixKitDocumentCreator.Test.StubDocsClient do
  @moduledoc """
  Stub for `PhoenixKitDocumentCreator.GoogleDocsClient` that records calls in a
  per-test Agent without issuing any real HTTP requests.

  ## Setup

  In your test or setup block:

      stub_google_docs_client!()    # from StubDocsClientHelpers

  ## Concurrency

  Each test gets its own Agent (stored in process dictionary under
  `:stub_docs_client_agent`), so tests can safely run `async: false` (required
  when sharing the `:docs_client` Application env).

  ## Default stub behaviour

  - `copy_document/1` → `{:ok, "copy-of-<source_id>"}`
  - `append_template/2` → `{:ok, {100, 200}}`
  - `substitute_in_range/5` → `:ok`
  - `delete_document/1` → `:ok`

  Override specific calls via the `stub_*_error!` helpers in
  `StubDocsClientHelpers`.
  """

  def start_agent do
    {:ok, pid} = Agent.start_link(fn -> %{calls: [], overrides: %{}} end)
    Process.put(:stub_docs_client_agent, pid)
    pid
  end

  defp agent do
    case Process.get(:stub_docs_client_agent) do
      nil -> raise "StubDocsClient agent not started — call stub_google_docs_client!() in setup"
      pid -> pid
    end
  end

  defp record(call) do
    Agent.update(agent(), fn state -> Map.update!(state, :calls, &[call | &1]) end)
  end

  defp override_for(key) do
    Agent.get(agent(), fn state -> Map.get(state.overrides, key) end)
  end

  def add_override(key, response) do
    Agent.update(agent(), fn state -> put_in(state, [:overrides, key], response) end)
  end

  def calls do
    Agent.get(agent(), fn state -> Enum.reverse(state.calls) end)
  end

  def stop_agent do
    case Process.get(:stub_docs_client_agent) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end

  # ── GoogleDocsClient contract ────────────────────────────────────────

  def copy_document(source_id) do
    record(:copy_document)

    case override_for(:copy_document) do
      nil -> {:ok, "copy-of-#{source_id}"}
      {:error, _} = err -> err
    end
  end

  def append_template(_target_doc_id, _template_doc_id) do
    record(:append_template)

    case override_for(:append_template) do
      nil -> {:ok, {100, 200}}
      {:ok, range} -> {:ok, range}
      {:error, _} = err -> err
    end
  end

  def document_content_range(_doc_id) do
    record(:document_content_range)
    {:ok, {1, 99}}
  end

  def substitute_all_sections(doc_id, _sections, _ranges) do
    record(:substitute_all_sections)

    case override_for({:substitute_all_sections, doc_id}) ||
           override_for(:substitute_all_sections) do
      nil -> :ok
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  def delete_document(doc_id) do
    record({:delete_document, doc_id})

    case override_for(:delete_document) do
      nil -> :ok
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # Passthrough for any function not intercepted (e.g. get_document_text
  # used by the real append_template — not needed since we stub at this level).
  def get_document_text(_doc_id), do: {:ok, ""}
end

defmodule PhoenixKitDocumentCreator.Test.StubDocsClientHelpers do
  @moduledoc "Convenience helpers for using StubDocsClient in tests."

  alias PhoenixKitDocumentCreator.Test.StubDocsClient

  @doc "Install the stub docs client for the current test. Call from setup/0."
  def stub_google_docs_client! do
    StubDocsClient.start_agent()
    prev = Application.get_env(:phoenix_kit_document_creator, :docs_client)
    Application.put_env(:phoenix_kit_document_creator, :docs_client, StubDocsClient)

    ExUnit.Callbacks.on_exit(fn ->
      StubDocsClient.stop_agent()

      if prev do
        Application.put_env(:phoenix_kit_document_creator, :docs_client, prev)
      else
        Application.delete_env(:phoenix_kit_document_creator, :docs_client)
      end
    end)

    :ok
  end

  @doc "Assert that Google Docs wrapper calls were made in the given order."
  def assert_google_docs_calls_in_order(expected) do
    actual =
      Enum.map(StubDocsClient.calls(), fn
        call when is_atom(call) -> call
        {name, _} -> name
      end)

    # Normalize: filter to only the expected call types for comparison
    filtered = Enum.filter(actual, &(&1 in expected))

    ExUnit.Assertions.assert(
      filtered == expected,
      "Expected Google Docs calls in order #{inspect(expected)}, got #{inspect(actual)}"
    )
  end

  @doc "Assert that a Google Doc with the given ID was deleted."
  def assert_google_doc_deleted!(doc_id) do
    deleted =
      StubDocsClient.calls()
      |> Enum.any?(fn
        {:delete_document, ^doc_id} -> true
        _ -> false
      end)

    ExUnit.Assertions.assert(
      deleted,
      "Expected Google Doc #{doc_id} to be deleted, but delete_document was not called for it"
    )
  end

  @doc "Stub substitute_all_sections to return an error."
  def stub_substitute_in_range_error!(_range_key, error) do
    StubDocsClient.add_override(:substitute_all_sections, {:error, error})
  end

  @doc "Stub delete_document to return an error."
  def stub_delete_document_error!(error) do
    StubDocsClient.add_override(:delete_document, {:error, error})
  end
end
