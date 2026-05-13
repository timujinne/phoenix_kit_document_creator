defmodule PhoenixKitDocumentCreator.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitDocumentCreator.Web.DocumentsLiveTest do
        use PhoenixKitDocumentCreator.LiveCase

        test "renders the documents list", %{conn: conn} do
          conn = put_test_scope(conn, fake_scope())
          {:ok, _view, html} = live(conn, "/en/admin/document-creator")
          assert html =~ "Documents"
        end
      end

  ## Scope assigns

  The Documents LiveView reads `socket.assigns[:phoenix_kit_current_scope]`
  and `socket.assigns[:phoenix_kit_current_user]` to determine the actor
  for activity-log entries via `actor_opts/1`. Tests plug a fake scope
  via `put_test_scope/2`, paired with `fake_scope/1`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitDocumentCreator.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitDocumentCreator.ActivityLogAssertions
      import PhoenixKitDocumentCreator.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.
  Mirrors the shape used in `phoenix_kit_hello_world` /
  `phoenix_kit_locations` test infra.

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role atoms; `[:owner]` makes `admin?/1` true
    * `:permissions` — list of module-key strings; `["document_creator"]`
      grants module access in `Scope.has_module_access?/2`
    * `:authenticated?` — defaults to `true`
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, [:owner])
    permissions = Keyword.get(opts, :permissions, ["document_creator"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: MapSet.new(roles),
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the test
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end

  @doc """
  Mounts a LiveComponent in isolation for testing, returning `{:ok, view, html}`.

  Accepts the component module and a map of assigns. The returned view
  is a full Phoenix.LiveViewTest view backed by
  `PhoenixKitDocumentCreator.Test.ComponentHostLive`, so all LiveViewTest
  helpers (element/2, render_click/1, render_change/2, etc.) work normally.

  The host LiveView forwards `{:update, assigns}` messages so tests can
  simulate external re-renders:

      send(view.pid, {:update, %{current_selection: ["uuid-1"]}})

  Messages the component sends via `send(self(), ...)` land in the
  test process inbox because the host LiveView forwards unknown messages
  back to the test process.
  """
  def render_live(component, assigns) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "component_host_module" => component,
        "component_host_assigns" => assigns,
        "component_host_test_pid" => self()
      })

    Phoenix.LiveViewTest.__isolated__(
      conn,
      PhoenixKitDocumentCreator.Test.Endpoint,
      PhoenixKitDocumentCreator.Test.ComponentHostLive,
      []
    )
  end
end

defmodule PhoenixKitDocumentCreator.Test.ComponentHostLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket) do
    component = session["component_host_module"]
    assigns = session["component_host_assigns"]
    test_pid = session["component_host_test_pid"]

    socket =
      socket
      |> assign(:comp_module, component)
      |> assign(:comp_assigns, assigns)
      |> assign(:test_pid, test_pid)

    {:ok, socket}
  end

  @impl true
  def handle_info({:update, new_assigns}, socket) do
    merged = Map.merge(socket.assigns.comp_assigns, new_assigns)
    {:noreply, assign(socket, :comp_assigns, merged)}
  end

  def handle_info(msg, socket) do
    send(socket.assigns.test_pid, msg)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="component-host">
      <.live_component module={@comp_module} {@comp_assigns} />
    </div>
    """
  end
end
