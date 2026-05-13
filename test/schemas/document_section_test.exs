defmodule PhoenixKitDocumentCreator.Schemas.DocumentSectionTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Schemas.DocumentSection

  @doc_uuid Ecto.UUID.generate()
  @user_uuid Ecto.UUID.generate()

  @valid_attrs %{
    document_uuid: @doc_uuid,
    position: 0,
    created_by_uuid: @user_uuid
  }

  defp changeset(attrs) do
    DocumentSection.changeset(%DocumentSection{}, attrs)
  end

  describe "changeset/2 with valid data" do
    test "is valid with required fields" do
      cs = changeset(@valid_attrs)
      assert cs.valid?
    end

    test "accepts optional template_uuid" do
      tmpl_uuid = Ecto.UUID.generate()
      cs = changeset(Map.put(@valid_attrs, :template_uuid, tmpl_uuid))
      assert cs.valid?
    end

    test "accepts variable_values map" do
      cs = changeset(Map.put(@valid_attrs, :variable_values, %{"client" => "Acme"}))
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :variable_values) == %{"client" => "Acme"}
    end

    test "accepts image_params map" do
      cs = changeset(Map.put(@valid_attrs, :image_params, %{"opacity" => 1.0}))
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :image_params) == %{"opacity" => 1.0}
    end

    test "accepts position of 0" do
      cs = changeset(@valid_attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :position) == 0
    end

    test "accepts positive positions" do
      cs = changeset(Map.put(@valid_attrs, :position, 5))
      assert cs.valid?
    end
  end

  describe "changeset/2 with invalid data" do
    test "is invalid without document_uuid" do
      cs = changeset(Map.delete(@valid_attrs, :document_uuid))
      refute cs.valid?
      assert %{document_uuid: ["can't be blank"]} = errors_on(cs)
    end

    test "is invalid without position" do
      cs = changeset(Map.delete(@valid_attrs, :position))
      refute cs.valid?
      assert %{position: ["can't be blank"]} = errors_on(cs)
    end

    test "is invalid without created_by_uuid" do
      cs = changeset(Map.delete(@valid_attrs, :created_by_uuid))
      refute cs.valid?
      assert %{created_by_uuid: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects negative position" do
      cs = changeset(Map.put(@valid_attrs, :position, -1))
      refute cs.valid?
      assert %{position: [_]} = errors_on(cs)
    end
  end

  describe "schema defaults" do
    test "default field values on struct" do
      section = %DocumentSection{}
      assert section.variable_values == %{}
      assert section.image_params == %{}
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
