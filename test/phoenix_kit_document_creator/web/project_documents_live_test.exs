defmodule PhoenixKitDocumentCreator.Web.ProjectDocumentsLiveTest do
  @moduledoc """
  The projects-hub Documents tab: `can_write` is the host's answer for THIS
  project, so attach and detach must also check the document — a crafted
  event must not take another project's document or unlink it.
  """

  use PhoenixKitDocumentCreator.LiveCase, async: false

  alias PhoenixKitDocumentCreator.Schemas.Document
  alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo
  alias PhoenixKitDocumentCreator.Web.ProjectDocumentsLive

  defp doc_fixture(attrs \\ %{}) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(
        Map.merge(
          %{
            name: "Doc #{System.unique_integer([:positive])}",
            google_doc_id: "gdoc-#{System.unique_integer([:positive])}",
            status: "published"
          },
          attrs
        )
      )
      |> TestRepo.insert()

    doc
  end

  defp project_fixture do
    uuid = Ecto.UUID.generate()

    TestRepo.query!(
      "INSERT INTO phoenix_kit_projects (uuid, name) VALUES ($1, $2)",
      [Ecto.UUID.dump!(uuid), "Project #{System.unique_integer([:positive])}"]
    )

    uuid
  end

  defp mount_tab(conn, project_uuid, can_write \\ true) do
    {:ok, view, _html} =
      live_isolated(conn, ProjectDocumentsLive,
        session: %{"project_uuid" => project_uuid, "can_write" => can_write}
      )

    view
  end

  defp project_of(doc), do: TestRepo.get!(Document, doc.uuid).project_uuid

  test "attach links an unlinked document to this project", %{conn: conn} do
    project = project_fixture()
    doc = doc_fixture()

    view = mount_tab(conn, project)
    render_submit(view, "attach", %{"document_uuid" => doc.uuid})

    assert project_of(doc) == project
  end

  test "attach refuses a document linked to another project", %{conn: conn} do
    mine = project_fixture()
    theirs = project_fixture()
    doc = doc_fixture(%{project_uuid: theirs})

    view = mount_tab(conn, mine)
    render_submit(view, "attach", %{"document_uuid" => doc.uuid})

    assert project_of(doc) == theirs
  end

  test "attach refuses a trashed document the tab does not offer", %{conn: conn} do
    project = project_fixture()
    doc = doc_fixture(%{status: "trashed"})

    view = mount_tab(conn, project)
    render_submit(view, "attach", %{"document_uuid" => doc.uuid})

    assert project_of(doc) == nil
  end

  test "detach unlinks a document of this project", %{conn: conn} do
    project = project_fixture()
    doc = doc_fixture(%{project_uuid: project})

    view = mount_tab(conn, project)
    render_click(view, "detach", %{"document_uuid" => doc.uuid})

    assert project_of(doc) == nil
  end

  test "detach refuses a document linked to another project", %{conn: conn} do
    mine = project_fixture()
    theirs = project_fixture()
    doc = doc_fixture(%{project_uuid: theirs})

    view = mount_tab(conn, mine)
    render_click(view, "detach", %{"document_uuid" => doc.uuid})

    assert project_of(doc) == theirs
  end

  test "without can_write neither event writes", %{conn: conn} do
    project = project_fixture()
    linked = doc_fixture(%{project_uuid: project})
    unlinked = doc_fixture()

    view = mount_tab(conn, project, false)
    render_submit(view, "attach", %{"document_uuid" => unlinked.uuid})
    render_click(view, "detach", %{"document_uuid" => linked.uuid})

    assert project_of(unlinked) == nil
    assert project_of(linked) == project
  end

  test "a malformed document uuid is a no-op", %{conn: conn} do
    view = mount_tab(conn, project_fixture())
    render_submit(view, "attach", %{"document_uuid" => "not-a-uuid"})
    render_click(view, "detach", %{"document_uuid" => "not-a-uuid"})
    assert render(view) =~ "Documents"
  end
end
