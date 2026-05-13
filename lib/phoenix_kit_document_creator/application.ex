defmodule PhoenixKitDocumentCreator.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # PhoenixKit.Supervisor is started by the host app (per PhoenixKit
    # convention); starting it here would race with the host's supervision
    # tree and crash with :already_started.
    children = oban_children()

    opts = [strategy: :one_for_one, name: PhoenixKitDocumentCreator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Oban supervision is conditional on test-env / parent-app providing the
  # config under `:phoenix_kit_document_creator, Oban`. The orphan-doc
  # sweeper worker (Task 5d) hasn't shipped yet, so config is typically
  # absent; in that case we skip the Oban child entirely instead of
  # crashing the supervisor with `Keyword.get(nil, ...)`.
  defp oban_children do
    case Application.get_env(:phoenix_kit_document_creator, Oban) do
      nil -> []
      config -> [{Oban, config}]
    end
  end
end
