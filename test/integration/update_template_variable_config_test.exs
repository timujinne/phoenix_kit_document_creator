if Code.ensure_loaded?(PhoenixKitDocumentCreator.DataCase) do
  defmodule PhoenixKitDocumentCreator.Integration.UpdateTemplateVariableConfigTest do
    use PhoenixKitDocumentCreator.DataCase, async: true

    alias PhoenixKitDocumentCreator.Documents
    alias PhoenixKitDocumentCreator.Schemas.Template

    describe "update_template_variable_config/3" do
      setup do
        {:ok, template} =
          %Template{}
          |> Template.changeset(%{
            name: "T",
            google_doc_id: "test-doc-id-#{System.unique_integer([:positive])}",
            variables: [
              %{
                "name" => "logo",
                "label" => "Logo",
                "type" => "image",
                "required" => false,
                "default" => nil,
                "config" => %{"default_width_px" => 400}
              },
              %{
                "name" => "photos",
                "label" => "Photos",
                "type" => "image_list",
                "required" => false,
                "default" => nil,
                "config" => %{
                  "default_width_px" => 400,
                  "separator" => "newline",
                  "max_count" => nil
                }
              }
            ]
          })
          |> Repo.insert()

        {:ok, template: template}
      end

      test "updates default_width_px for an image variable", %{template: t} do
        assert {:ok, _updated} =
                 Documents.update_template_variable_config(
                   t.google_doc_id,
                   "logo",
                   %{"default_width_px" => 500}
                 )

        reloaded = Repo.reload(t)
        logo_var = Enum.find(reloaded.variables, &(&1["name"] == "logo"))
        assert logo_var["config"]["default_width_px"] == 500
      end

      test "preserves other vars and other config keys", %{template: t} do
        {:ok, _} =
          Documents.update_template_variable_config(
            t.google_doc_id,
            "photos",
            %{"separator" => "space"}
          )

        reloaded = Repo.reload(t)
        photos_var = Enum.find(reloaded.variables, &(&1["name"] == "photos"))
        assert photos_var["config"]["separator"] == "space"
        assert photos_var["config"]["default_width_px"] == 400
        assert photos_var["config"]["max_count"] == nil

        logo_var = Enum.find(reloaded.variables, &(&1["name"] == "logo"))
        assert logo_var["config"]["default_width_px"] == 400
      end

      test "coerces integer-shaped strings to integers", %{template: t} do
        {:ok, _} =
          Documents.update_template_variable_config(
            t.google_doc_id,
            "logo",
            %{"default_width_px" => "650"}
          )

        reloaded = Repo.reload(t)
        logo_var = Enum.find(reloaded.variables, &(&1["name"] == "logo"))
        assert logo_var["config"]["default_width_px"] == 650
      end

      test "returns :not_found for missing template" do
        assert {:error, :not_found} =
                 Documents.update_template_variable_config(
                   "no-such-doc-id",
                   "logo",
                   %{"default_width_px" => 500}
                 )
      end

      test "empty default_width_px is dropped, existing value preserved", %{template: t} do
        {:ok, _} =
          Documents.update_template_variable_config(
            t.google_doc_id,
            "logo",
            %{"default_width_px" => ""}
          )

        reloaded = Repo.reload(t)
        logo_var = Enum.find(reloaded.variables, &(&1["name"] == "logo"))
        assert logo_var["config"]["default_width_px"] == 400
      end

      test "empty max_count means nil (no limit)", %{template: t} do
        {:ok, _} =
          Documents.update_template_variable_config(
            t.google_doc_id,
            "photos",
            %{"max_count" => ""}
          )

        reloaded = Repo.reload(t)
        photos_var = Enum.find(reloaded.variables, &(&1["name"] == "photos"))
        assert photos_var["config"]["max_count"] == nil
      end

      test "garbage string in default_width_px is dropped silently", %{template: t} do
        {:ok, _} =
          Documents.update_template_variable_config(
            t.google_doc_id,
            "logo",
            %{"default_width_px" => "abc"}
          )

        reloaded = Repo.reload(t)
        logo_var = Enum.find(reloaded.variables, &(&1["name"] == "logo"))
        assert logo_var["config"]["default_width_px"] == 400
      end
    end
  end
end
