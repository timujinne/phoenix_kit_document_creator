defmodule PhoenixKitDocumentCreator.Schemas.TemplatePresetTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Schemas.TemplatePreset

  @user_uuid Ecto.UUID.generate()

  @valid_attrs %{
    name: "Standard Invoice",
    created_by_uuid: @user_uuid
  }

  defp changeset(attrs) do
    TemplatePreset.changeset(%TemplatePreset{}, attrs)
  end

  describe "changeset/2 with valid data" do
    test "is valid with only required fields" do
      cs = changeset(@valid_attrs)
      assert cs.valid?
    end

    test "accepts optional description" do
      cs = changeset(Map.put(@valid_attrs, :description, "A standard invoice preset"))
      assert cs.valid?
    end

    test "accepts optional category" do
      cs = changeset(Map.put(@valid_attrs, :category, "invoices"))
      assert cs.valid?
    end

    test "accepts optional scope_type and scope_id" do
      cs = changeset(Map.merge(@valid_attrs, %{scope_type: "organization", scope_id: "org-123"}))
      assert cs.valid?
    end

    test "accepts sections array" do
      sections = [%{"template_uuid" => Ecto.UUID.generate(), "position" => 0}]
      cs = changeset(Map.put(@valid_attrs, :sections, sections))
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :sections) == sections
    end

    test "accepts empty sections array" do
      cs = changeset(Map.put(@valid_attrs, :sections, []))
      assert cs.valid?
    end

    test "accepts name at exactly 255 characters" do
      cs = changeset(Map.put(@valid_attrs, :name, String.duplicate("x", 255)))
      assert cs.valid?
    end
  end

  describe "changeset/2 with invalid data" do
    test "is invalid without name" do
      cs = changeset(Map.delete(@valid_attrs, :name))
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "is invalid with empty name" do
      cs = changeset(Map.put(@valid_attrs, :name, ""))
      refute cs.valid?
    end

    test "is invalid with name exceeding 255 characters" do
      cs = changeset(Map.put(@valid_attrs, :name, String.duplicate("x", 256)))
      refute cs.valid?
      assert %{name: [msg]} = errors_on(cs)
      assert msg =~ "at most"
    end

    test "is invalid without created_by_uuid" do
      cs = changeset(Map.delete(@valid_attrs, :created_by_uuid))
      refute cs.valid?
      assert %{created_by_uuid: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "schema defaults" do
    test "default field values on struct" do
      preset = %TemplatePreset{}
      assert preset.sections == []
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
