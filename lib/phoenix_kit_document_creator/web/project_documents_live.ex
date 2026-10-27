defmodule PhoenixKitDocumentCreator.Web.ProjectDocumentsLive do
  @moduledoc """
  The **Documents** tab for the `phoenix_kit_projects` hub — this
  module's `phoenix_kit_project_extensions/0` contribution.

  Unlike the config-linked tabs (CRM/entities/publishing), linkage here
  is PER-DOCUMENT: V1 of this module's own migration chain added
  `project_uuid` to documents, so a project can hold many documents and
  a document belongs to at most one project. The tab lists the linked
  documents, attaches unlinked ones, detaches, and links out to the
  Google editor / the Document Creator admin.

  Hub session contract (see `PhoenixKitHelloWorld.Web.ProjectHelloTabLive`):
  off-router mount, no `handle_params/3`; `"can_write"` (HOST-resolved
  authorization) gates attach/detach. Both events also check the document
  itself: attach takes only an unlinked document (one this tab offers),
  detach only a document linked to this tab's project — `can_write` is
  about this project, never about another project's documents. Every read rescues to an empty
  state — a provider hiccup must never crash the host project page.
  """

  use Phoenix.LiveView

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Paths

  @impl true
  def mount(_params, session, socket) do
    project_uuid = session["project_uuid"]

    {:ok,
     socket
     |> assign(
       project_uuid: project_uuid,
       can_write: session["can_write"] == true
     )
     |> reload()}
  end

  @impl true
  def handle_event("attach", %{"document_uuid" => doc_uuid}, socket) do
    with true <- socket.assigns.can_write,
         uuid when is_binary(uuid) <- socket.assigns.project_uuid,
         {:ok, _} <- safe(fn -> Documents.attach_document_to_project(doc_uuid, uuid) end) do
      {:noreply, reload(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("detach", %{"document_uuid" => doc_uuid}, socket) do
    with true <- socket.assigns.can_write,
         uuid when is_binary(uuid) <- socket.assigns.project_uuid,
         {:ok, _} <-
           safe(fn -> Documents.detach_document_from_project(doc_uuid, uuid) end) do
      {:noreply, reload(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp reload(socket) do
    case socket.assigns.project_uuid do
      nil ->
        assign(socket, documents: [], unlinked: [])

      uuid ->
        assign(socket,
          documents: safe(fn -> Documents.list_documents_for_project(uuid) end) || [],
          unlinked:
            if(socket.assigns.can_write,
              do: safe(fn -> Documents.list_unlinked_documents() end) || [],
              else: []
            )
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-3">
        <span class="hero-document-text w-5 h-5 opacity-70"></span>
        <div class="min-w-0 grow">
          <h3 class="font-semibold">Documents</h3>
          <p class="text-xs opacity-60">{doc_count_label(length(@documents))}</p>
        </div>
        <.link navigate={Paths.documents()} class="btn btn-ghost btn-sm gap-1">
          Open Document Creator
        </.link>
      </div>

      <%= if @documents == [] do %>
        <div class="card border border-dashed border-base-300 bg-base-100">
          <div class="card-body items-center text-center py-8">
            <p class="text-sm opacity-70">No documents linked to this project yet.</p>
          </div>
        </div>
      <% else %>
        <div class="divide-y divide-base-200 rounded-lg border border-base-200">
          <div :for={doc <- @documents} class="flex items-center gap-3 px-3 py-2">
            <span class="hero-document w-4 h-4 opacity-50 shrink-0"></span>
            <span class="text-sm font-medium truncate min-w-0">{doc["name"]}</span>
            <span class="badge badge-ghost badge-xs shrink-0">{doc["status"]}</span>
            <div class="flex items-center gap-1 ml-auto shrink-0">
              <a
                :if={edit_url(doc)}
                href={edit_url(doc)}
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-ghost btn-xs gap-1"
              >
                Edit in Google Docs
              </a>
              <button
                :if={@can_write}
                type="button"
                phx-click="detach"
                phx-value-document_uuid={doc["uuid"]}
                data-confirm={"Detach \"#{doc["name"]}\" from this project?"}
                class="btn btn-ghost btn-xs text-error"
              >
                Detach
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <form
        :if={@can_write and @unlinked != []}
        phx-submit="attach"
        class="flex items-end gap-2"
      >
        <label class="fieldset flex-1 max-w-md">
          <span class="fieldset-legend text-xs opacity-70 mb-1">Attach an existing document</span>
          <select name="document_uuid" class="select select-sm">
            <option :for={doc <- @unlinked} value={doc["uuid"]}>{doc["name"]}</option>
          </select>
        </label>
        <button type="submit" class="btn btn-primary btn-sm">Attach</button>
      </form>
    </div>
    """
  end

  defp doc_count_label(0), do: "No linked documents"
  defp doc_count_label(1), do: "1 linked document"
  defp doc_count_label(n), do: "#{n} linked documents"

  defp edit_url(doc) do
    case doc["id"] do
      id when is_binary(id) and id != "" -> safe(fn -> GoogleDocsClient.get_edit_url(id) end)
      _ -> nil
    end
  end

  # A provider hiccup degrades to the empty state — never crash the host.
  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
