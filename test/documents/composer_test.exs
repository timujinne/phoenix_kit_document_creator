defmodule PhoenixKitDocumentCreator.Documents.ComposerTest do
  use PhoenixKitDocumentCreator.DataCase, async: true

  alias PhoenixKitDocumentCreator.Documents.Composer

  describe "validate_sections/2" do
    test "rejects empty list" do
      assert {:error, :empty_sections} = Composer.validate_sections([], all_templates: [])
    end

    test "rejects duplicate positions" do
      t = Ecto.UUID.generate()

      sections = [
        %{template_uuid: t, position: 0, variable_values: %{}, image_params: %{}},
        %{template_uuid: t, position: 0, variable_values: %{}, image_params: %{}}
      ]

      assert {:error, {:duplicate_positions, [0]}} =
               Composer.validate_sections(sections, all_templates: [%{uuid: t, published: true}])
    end

    test "rejects unknown template_uuid" do
      missing = Ecto.UUID.generate()
      sections = [%{template_uuid: missing, position: 0, variable_values: %{}, image_params: %{}}]

      assert {:error, {:unknown_templates, [^missing]}} =
               Composer.validate_sections(sections, all_templates: [])
    end

    test "rejects unpublished templates" do
      t = Ecto.UUID.generate()
      sections = [%{template_uuid: t, position: 0, variable_values: %{}, image_params: %{}}]

      assert {:error, {:unpublished_templates, [^t]}} =
               Composer.validate_sections(sections,
                 all_templates: [%{uuid: t, published: false}]
               )
    end

    test "accepts a well-formed list" do
      [a, b] = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      sections = [
        %{template_uuid: a, position: 0, variable_values: %{}, image_params: %{}},
        %{template_uuid: b, position: 1, variable_values: %{}, image_params: %{}}
      ]

      assert :ok =
               Composer.validate_sections(sections,
                 all_templates: [
                   %{uuid: a, published: true},
                   %{uuid: b, published: true}
                 ]
               )
    end
  end
end
