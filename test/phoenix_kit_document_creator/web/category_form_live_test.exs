defmodule PhoenixKitDocumentCreator.Web.CategoryFormLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.Taxonomy

  test "creates a category", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, view, _} = live(conn, "/en/admin/document-creator/categories/new")

    view
    |> form("form", category: %{name: "Legal"})
    |> render_submit()

    assert [%{name: "Legal"}] = Taxonomy.list_categories()
  end

  test "edits an existing category", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, cat} = Taxonomy.create_category(%{name: "Old"})
    {:ok, view, _} = live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/edit")

    view |> form("form", category: %{name: "New"}) |> render_submit()

    assert Taxonomy.get_category(cat.uuid).name == "New"
  end

  describe "back to the Categories page with the category selected" do
    @page "/en/admin/document-creator/categories"

    test "after an edit, and from Cancel and the back arrow", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Old"})
      back = @page <> "?category=#{cat.uuid}"
      {:ok, view, _} = live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/edit")

      assert has_element?(view, ~s{a[href="#{back}"]}, "Cancel")
      assert has_element?(view, ~s{a[href="#{back}"] .hero-arrow-left})

      view |> form("form", category: %{name: "New"}) |> render_submit()

      assert_redirect(view, back)
    end

    test "a new category opens itself; its Cancel goes to the plain list", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/document-creator/categories/new")

      assert has_element?(view, ~s{a[href="#{@page}"]}, "Cancel")

      view |> form("form", category: %{name: "Legal"}) |> render_submit()

      [cat] = Taxonomy.list_categories()
      assert_redirect(view, @page <> "?category=#{cat.uuid}")
    end
  end
end
