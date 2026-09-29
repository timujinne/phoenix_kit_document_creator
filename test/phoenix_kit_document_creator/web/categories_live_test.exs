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

  describe "locale-aware category/type names" do
    # `live/2` runs the LiveView in its own process, so `Gettext.put_locale/2`
    # called from the test process never reaches it — DC has no locale-sync
    # on_mount hook of its own (that's the host app's job, see
    # `Andi.Locales.sync_from_phoenix_kit/0`). Rendering with an untranslated
    # category still exercises the real code path (`Taxonomy.localized_name/2`
    # is called either way and falls back to `name`), just not the "different
    # locale, different text" branch — that one is covered directly by the
    # `Taxonomy.localized_name/2` unit tests in `taxonomy_test.exs`.
    test "renders the (untranslated) name via the same localized_name/2 path", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Klient"})

      {:ok, _cat} =
        Taxonomy.update_category(cat, %{
          data: %{
            "_primary_language" => "et",
            "et" => %{"_name" => "Klient"},
            "ru" => %{"_name" => "Клиент"}
          }
        })

      {:ok, _type} = Taxonomy.create_type(%{name: "Hooldusjuhend", category_uuid: cat.uuid})

      {:ok, view, html} = live(conn, "/en/admin/document-creator/categories")
      # Default (primary/"et") tab of a category with no "en" override falls
      # back to the denormalized name, same as before this change.
      assert html =~ "Klient"

      view
      |> element("button[phx-click='select_category'][phx-value-uuid='#{cat.uuid}']")
      |> render_click()

      assert render(view) =~ "Hooldusjuhend"
    end
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

  describe "template count next to each type" do
    alias PhoenixKitDocumentCreator.Schemas.Template
    alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo

    defp file_template!(category_uuid, type_uuid, status \\ "published") do
      {:ok, tmpl} =
        %Template{}
        |> Template.changeset(%{
          name: "Tmpl #{System.unique_integer()}",
          google_doc_id: "gdoc_#{System.unique_integer()}",
          status: status
        })
        |> TestRepo.insert()

      {:ok, _} =
        Taxonomy.set_template_memberships(tmpl.uuid, [
          %{category_uuid: category_uuid, type_uuid: type_uuid}
        ])

      tmpl
    end

    defp open_category(conn, cat) do
      {:ok, view, _html} = live(conn, "/en/admin/document-creator/categories")

      view
      |> element("button[phx-click='select_category'][phx-value-uuid='#{cat.uuid}']")
      |> render_click()

      view
    end

    test "shows the published templates of each type right after its name", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Contracts"})
      {:ok, main} = Taxonomy.create_type(%{name: "Main agreement", category_uuid: cat.uuid})
      {:ok, acts} = Taxonomy.create_type(%{name: "Acts", category_uuid: cat.uuid})
      file_template!(cat.uuid, main.uuid)
      file_template!(cat.uuid, main.uuid)
      file_template!(cat.uuid, main.uuid, "trashed")

      view = open_category(conn, cat)

      assert has_element?(view, "#type-template-count-#{main.uuid}", ~r/^\s*2\s*$/)
      assert has_element?(view, ~s{#type-template-count-#{main.uuid}[title="2 templates"]})
      assert has_element?(view, "#type-template-count-#{acts.uuid}", ~r/^\s*0\s*$/)
      assert has_element?(view, ~s{#type-template-count-#{acts.uuid}[title="0 templates"]})
    end

    test "follows a template filed into the type while the page is open", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Contracts"})
      {:ok, acts} = Taxonomy.create_type(%{name: "Acts", category_uuid: cat.uuid})

      view = open_category(conn, cat)
      assert has_element?(view, "#type-template-count-#{acts.uuid}", ~r/^\s*0\s*$/)

      file_template!(cat.uuid, acts.uuid)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#type-template-count-#{acts.uuid}", ~r/^\s*1\s*$/)
      assert has_element?(view, ~s{#type-template-count-#{acts.uuid}[title="1 template"]})
    end

    test "follows a template trashed or restored while the page is open", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Contracts"})
      {:ok, acts} = Taxonomy.create_type(%{name: "Acts", category_uuid: cat.uuid})
      tmpl = file_template!(cat.uuid, acts.uuid)

      view = open_category(conn, cat)
      assert has_element?(view, "#type-template-count-#{acts.uuid}", ~r/^\s*1\s*$/)

      # What delete_template/2 and restore_template/2 do after the DB write:
      # a :files_changed broadcast, no taxonomy event.
      tmpl = tmpl |> Ecto.Changeset.change(status: "trashed") |> TestRepo.update!()
      PhoenixKitDocumentCreator.Documents.broadcast_files_changed()
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#type-template-count-#{acts.uuid}", ~r/^\s*0\s*$/)

      tmpl |> Ecto.Changeset.change(status: "published") |> TestRepo.update!()
      PhoenixKitDocumentCreator.Documents.broadcast_files_changed()
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#type-template-count-#{acts.uuid}", ~r/^\s*1\s*$/)
    end

    test "an unexpected message on the files topic does not crash the page", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Contracts"})
      {:ok, acts} = Taxonomy.create_type(%{name: "Acts", category_uuid: cat.uuid})

      view = open_category(conn, cat)
      PhoenixKit.PubSubHelper.broadcast(Documents.pubsub_topic(), {:something_else, self()})
      _ = :sys.get_state(view.pid)

      assert Process.alive?(view.pid)
      assert has_element?(view, "#type-template-count-#{acts.uuid}", ~r/^\s*0\s*$/)
    end

    test "trashed types carry no count", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Contracts"})
      {:ok, acts} = Taxonomy.create_type(%{name: "Acts", category_uuid: cat.uuid})
      {:ok, _} = Taxonomy.trash_type(acts)

      view = open_category(conn, cat)
      render_click(view, "switch_status", %{"target" => "types", "mode" => "trashed"})

      assert render(view) =~ "Acts"
      refute has_element?(view, "#type-template-count-#{acts.uuid}")
    end
  end
end
