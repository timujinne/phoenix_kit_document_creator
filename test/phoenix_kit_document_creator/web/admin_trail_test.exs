defmodule PhoenixKitDocumentCreator.Web.AdminTrailTest do
  @moduledoc """
  The admin header trail of every Document Creator page — the four assigns
  core's header bar draws: `page_section` (+ `_path`), `page_crumbs` and
  `page_title`. The test layout has no bar, so the assigns are read off
  the LiveView process.
  """

  # Mounts the Documents and Settings pages, whose connected mount reads
  # Integrations — keep it clear of the StubIntegrations users.
  use PhoenixKitDocumentCreator.LiveCase, async: false

  alias PhoenixKitDocumentCreator.{Documents, Taxonomy}

  defp mount(conn, path) do
    {:ok, view, _html} = conn |> put_test_scope(fake_scope()) |> live(path)
    view
  end

  # {section, section_path, [{crumb label, crumb path}], title}
  defp trail(view) do
    assigns = :sys.get_state(view.pid).socket.assigns

    {assigns[:page_section], assigns[:page_section_path],
     Enum.map(assigns[:page_crumbs] || [], &{&1.label, &1[:path]}), assigns[:page_title]}
  end

  defp taxonomy(_) do
    {:ok, cat} = Taxonomy.create_category(%{name: "Legal"})
    {:ok, type} = Taxonomy.create_type(%{name: "Contract", category_uuid: cat.uuid})

    {:ok, preset} =
      Documents.save_preset(%{
        name: "Standard bundle",
        scope_id: cat.uuid,
        created_by_uuid: Ecto.UUID.generate()
      })

    %{cat: cat, type: type, preset: preset}
  end

  @section {"Document Creator", "/en/admin/document-creator"}
  @categories {"Categories", "/en/admin/document-creator/categories"}

  describe "lists" do
    test "the Documents list is the landing page: the module is the title, no section",
         %{conn: conn} do
      assert trail(mount(conn, "/en/admin/document-creator")) ==
               {nil, nil, [], "Document Creator"}

      assert trail(mount(conn, "/en/admin/document-creator/documents")) ==
               {nil, nil, [], "Document Creator"}
    end

    test "Templates and Categories carry the module as their section", %{conn: conn} do
      {section, section_path} = @section

      assert trail(mount(conn, "/en/admin/document-creator/templates")) ==
               {section, section_path, [], "Templates"}

      assert trail(mount(conn, "/en/admin/document-creator/categories")) ==
               {section, section_path, [], "Categories"}
    end
  end

  describe "forms" do
    setup :taxonomy

    test "category: Categories / New category, Categories / <category> / Edit",
         %{conn: conn, cat: cat} do
      {section, section_path} = @section

      assert trail(mount(conn, "/en/admin/document-creator/categories/new")) ==
               {section, section_path, [@categories], "New category"}

      assert trail(mount(conn, "/en/admin/document-creator/categories/#{cat.uuid}/edit")) ==
               {section, section_path, [@categories, {"Legal", nil}], "Edit"}
    end

    test "type: the category is a text crumb, the type on top for an edit",
         %{conn: conn, cat: cat, type: type} do
      {section, section_path} = @section

      assert trail(mount(conn, "/en/admin/document-creator/categories/#{cat.uuid}/types/new")) ==
               {section, section_path, [@categories, {"Legal", nil}], "New type"}

      assert trail(mount(conn, "/en/admin/document-creator/types/#{type.uuid}/edit")) ==
               {section, section_path, [@categories, {"Legal", nil}, {"Contract", nil}], "Edit"}
    end

    test "preset: the category is a text crumb, the preset on top for an edit",
         %{conn: conn, cat: cat, preset: preset} do
      {section, section_path} = @section

      assert trail(mount(conn, "/en/admin/document-creator/categories/#{cat.uuid}/presets/new")) ==
               {section, section_path, [@categories, {"Legal", nil}], "New preset"}

      assert trail(mount(conn, "/en/admin/document-creator/presets/#{preset.uuid}/edit")) ==
               {section, section_path, [@categories, {"Legal", nil}, {"Standard bundle", nil}],
                "Edit"}
    end
  end

  describe "settings" do
    test "the module settings page lives in Settings", %{conn: conn} do
      assert trail(mount(conn, "/en/admin/settings/document-creator")) ==
               {"Settings", "/en/admin/settings", [], "Document Creator"}
    end
  end
end
