defmodule PhoenixKitDocumentCreator.Web.CategoriesLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.{Documents, Taxonomy}

  test "lists existing categories", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, _} = Taxonomy.create_category(%{name: "Financial"})
    {:ok, view, _html} = live(conn, "/en/admin/document-creator/categories")
    assert render(view) =~ "Financial"
  end

  test "selecting a category shows its types", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, cat} = Taxonomy.create_category(%{name: "C"})
    {:ok, _} = Taxonomy.create_type(%{name: "InvoiceType", category_uuid: cat.uuid})
    {:ok, view, _html} = live(conn, "/en/admin/document-creator/categories")

    view
    |> element("button[phx-click='select_category'][phx-value-uuid='#{cat.uuid}']")
    |> render_click()

    assert render(view) =~ "InvoiceType"
  end

  describe "presets panel" do
    test "lists presets of the selected category and deletes one", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Legal"})

      {:ok, preset} =
        Documents.save_preset(%{
          name: "Standard",
          scope_id: cat.uuid,
          created_by_uuid: Ecto.UUID.generate()
        })

      {:ok, view, _} = live(conn, "/en/admin/document-creator/categories")
      view |> element("button", "Legal") |> render_click()

      assert render(view) =~ "Standard"

      view
      |> element(~s{button[phx-value-uuid="#{preset.uuid}"][phx-click="delete_preset"]})
      |> render_click()

      assert Documents.list_presets(%{scope_id: cat.uuid}) == []
    end
  end
end
