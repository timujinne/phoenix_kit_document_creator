defmodule PhoenixKitDocumentCreator.Documents.RecipeAndPresetsTest do
  use PhoenixKitDocumentCreator.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.Template
  alias PhoenixKitDocumentCreator.Test.StubDocsClientHelpers

  import StubDocsClientHelpers

  defp insert_template!(opts \\ []) do
    unique = System.unique_integer([:positive])
    google_doc_id = Keyword.get(opts, :google_doc_id, "tmpl-#{unique}")
    published = Keyword.get(opts, :published, true)
    status = if published, do: "published", else: "trashed"

    {:ok, template} =
      %Template{}
      |> Template.changeset(%{
        name: "Template #{unique}",
        google_doc_id: google_doc_id,
        status: status
      })
      |> Repo.insert()

    template
  end

  setup do
    stub_google_docs_client!()
    :ok
  end

  describe "recipe_for/1" do
    test "returns sections in position order with all fields" do
      t1 = insert_template!(google_doc_id: "tmpl-r1", published: true)
      t2 = insert_template!(google_doc_id: "tmpl-r2", published: true)

      sections = [
        %{
          template_uuid: t1.uuid,
          position: 0,
          variable_values: %{"name" => "Alice"},
          image_params: %{}
        },
        %{
          template_uuid: t2.uuid,
          position: 1,
          variable_values: %{"name" => "Bob"},
          image_params: %{}
        }
      ]

      user = Ecto.UUID.generate()

      assert {:ok, doc} =
               Documents.create_composed_document(sections,
                 created_by_uuid: user,
                 name: "Recipe test doc"
               )

      t1uuid = t1.uuid
      t2uuid = t2.uuid

      assert [
               %{
                 template_uuid: ^t1uuid,
                 position: 0,
                 variable_values: %{"name" => "Alice"},
                 image_params: %{}
               },
               %{template_uuid: ^t2uuid, position: 1, variable_values: _, image_params: _}
             ] = Documents.recipe_for(doc)
    end
  end

  describe "save_preset/1 + list_presets/1" do
    test "round-trips and filters by (scope_type, scope_id, category)" do
      user = Ecto.UUID.generate()

      {:ok, _} =
        Documents.save_preset(%{
          name: "F1",
          category: "financial",
          scope_type: "order",
          scope_id: "ord-1",
          sections: [
            %{
              "template_uuid" => Ecto.UUID.generate(),
              "position" => 0,
              "variable_values" => %{},
              "image_params" => %{}
            }
          ],
          created_by_uuid: user
        })

      {:ok, _} =
        Documents.save_preset(%{
          name: "T1",
          category: "technical",
          scope_type: "sub_order",
          scope_id: "so-1",
          sections: [],
          created_by_uuid: user
        })

      assert [%{name: "F1"}] =
               Documents.list_presets(%{
                 category: "financial",
                 scope_type: "order",
                 scope_id: "ord-1"
               })

      assert [%{name: "T1"}] = Documents.list_presets(%{scope_type: "sub_order"})
    end

    test "save_preset returns changeset error for missing name" do
      assert {:error, %Ecto.Changeset{}} =
               Documents.save_preset(%{sections: [], created_by_uuid: Ecto.UUID.generate()})
    end

    test "list_presets returns all presets when no filter is given" do
      user = Ecto.UUID.generate()
      {:ok, _} = Documents.save_preset(%{name: "A", sections: [], created_by_uuid: user})
      {:ok, _} = Documents.save_preset(%{name: "B", sections: [], created_by_uuid: user})

      results = Documents.list_presets()
      assert length(results) >= 2
    end
  end

  describe "apply_preset/1" do
    test "drops sections whose template_uuid no longer exists and logs warning" do
      live = insert_template!(published: true)
      missing = Ecto.UUID.generate()

      {:ok, preset} =
        Documents.save_preset(%{
          name: "P",
          created_by_uuid: Ecto.UUID.generate(),
          sections: [
            %{
              "template_uuid" => live.uuid,
              "position" => 0,
              "variable_values" => %{},
              "image_params" => %{}
            },
            %{
              "template_uuid" => missing,
              "position" => 1,
              "variable_values" => %{},
              "image_params" => %{}
            }
          ]
        })

      live_uuid = live.uuid

      log =
        capture_log(fn ->
          assert {:ok, sections} = Documents.apply_preset(preset.uuid)
          assert [%{template_uuid: ^live_uuid, position: 0}] = sections
        end)

      assert log =~ "dropped"
      assert log =~ missing
    end

    test "returns {:error, :not_found} for missing preset uuid" do
      assert {:error, :not_found} = Documents.apply_preset(Ecto.UUID.generate())
    end
  end
end
