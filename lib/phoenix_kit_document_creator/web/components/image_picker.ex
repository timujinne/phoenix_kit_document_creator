defmodule PhoenixKitDocumentCreator.Web.Components.ImagePicker do
  @moduledoc """
  Generic image picker LiveComponent.

  Inputs (assigns):
    * `:id` — required
    * `:picker_id` — required `String.t()`; echoed back to the host in every
      change message so a single LiveView can host multiple pickers
    * `:scope_type` — opaque string (used by the host to resolve files)
    * `:scope_id` — opaque string (used by the host to resolve files)
    * `:mode` — `:single` or `:list`
    * `:current_selection` — `[file_uuid]` (OPTIONAL). Selection mode contract:
      - If the host wants to control selection externally, it MUST echo back
        the latest selection on every render (e.g. on receipt of the
        `:image_picker_changed` message). Otherwise an unrelated host re-render
        would clobber internal state.
      - If the host omits `:current_selection`, the component manages
        selection internally via `assign_new/2` (default `[]`).
    * `:files` — `[%{uuid: String.t(), name: String.t(), url: String.t()}]`
      provided by the host (host resolves storage scope to files)

  Output: on selection change the component calls
    `send(self(), {:image_picker_changed, picker_id, selection})`
  The host LiveView must implement `handle_info({:image_picker_changed, _, _}, socket)`.
  """
  use Phoenix.LiveComponent

  @page_size 50

  @impl true
  def update(assigns, socket) do
    # `assign_new(:current_selection, ...)` AFTER `assign(assigns)` ensures that
    # a host re-render which omits `:current_selection` does not clobber the
    # component's internally-managed selection. Hosts that want to control
    # selection externally MUST echo it back on every render (see moduledoc).
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:current_selection, fn -> [] end)
      |> assign_new(:filter, fn -> "" end)
      |> assign_new(:page, fn -> 0 end)
      |> compute_visible()

    {:ok, socket}
  end

  defp compute_visible(socket) do
    %{filter: q, page: page, files: files} = socket.assigns

    filtered =
      if q == "",
        do: files,
        else: Enum.filter(files, &String.contains?(String.downcase(&1.name), String.downcase(q)))

    visible = filtered |> Enum.drop(page * @page_size) |> Enum.take(@page_size)
    assign(socket, filtered_count: length(filtered), visible: visible)
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"q" => q}}, socket) do
    {:noreply, socket |> assign(filter: q, page: 0) |> compute_visible()}
  end

  def handle_event("next-page", _, socket) do
    max_page = div(socket.assigns.filtered_count - 1, @page_size)
    page = min(socket.assigns.page + 1, max(0, max_page))
    {:noreply, socket |> assign(page: page) |> compute_visible()}
  end

  def handle_event("prev-page", _, socket) do
    {:noreply, socket |> assign(page: max(0, socket.assigns.page - 1)) |> compute_visible()}
  end

  def handle_event("pick", %{"uuid" => uuid}, socket) do
    new =
      case socket.assigns.mode do
        :single -> [uuid]
        :list -> Enum.uniq(socket.assigns.current_selection ++ [uuid])
      end

    notify(socket, new)
    {:noreply, assign(socket, current_selection: new)}
  end

  defp notify(%{assigns: %{picker_id: picker_id}}, sel) do
    send(self(), {:image_picker_changed, picker_id, sel})
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <.form for={%{}} as={:filter} id="image-picker-filter" phx-change="filter" phx-target={@myself}>
        <input name="filter[q]" value={@filter} placeholder="Search by name" class="input input-bordered w-full" />
      </.form>

      <div class="grid grid-cols-4 gap-2">
        <button
          :for={f <- @visible}
          type="button"
          data-pick={f.uuid}
          phx-click="pick"
          phx-value-uuid={f.uuid}
          phx-target={@myself}
          class={["btn btn-ghost p-1", f.uuid in @current_selection && "ring ring-primary"]}
        >
          <img src={f.url} alt={f.name} class="h-20 object-contain" />
          <span class="text-xs truncate">{f.name}</span>
        </button>
      </div>

      <div class="flex justify-between">
        <button type="button" data-action="prev-page" phx-click="prev-page" phx-target={@myself} class="btn btn-sm">
          ‹
        </button>
        <span>{@page + 1} / {max(1, div(@filtered_count - 1, @page_size) + 1)}</span>
        <button type="button" data-action="next-page" phx-click="next-page" phx-target={@myself} class="btn btn-sm">
          ›
        </button>
      </div>
    </div>
    """
  end
end
