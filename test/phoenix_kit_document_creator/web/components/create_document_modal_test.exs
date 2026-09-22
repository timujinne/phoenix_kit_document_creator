defmodule PhoenixKitDocumentCreator.Web.Components.CreateDocumentModalTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitDocumentCreator.Web.Components.CreateDocumentModal

  # Render the modal as a function component so we can pin the
  # phx-disable-with attribute on the async-triggering buttons without
  # standing up a full LV mount with a Drive stub.

  describe "choose step" do
    test "Blank Document button has phx-disable-with" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "choose"
        )

      # The button text and the attribute must both appear on the same
      # button. Using a regex to keep the assertion specific.
      assert html =~ "phx-click=\"modal_create_blank\""
      assert html =~ ~r/phx-click="modal_create_blank"[^>]*phx-disable-with="Creating[^"]+"/
    end
  end

  describe "variables step" do
    test "Create Document submit button has phx-disable-with" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [],
          creating: false
        )

      assert html =~ "phx-submit=\"modal_create_from_template\""
      # The submit button has both `disabled={@creating}` and
      # `phx-disable-with` so a fast double-click is suppressed both
      # by server state and by the client transition.
      assert html =~ ~r/type="submit"[^>]*phx-disable-with="Creating[^"]+"/
    end
  end

  describe "open=false" do
    test "renders nothing visible when closed" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: false,
          templates: [],
          step: "choose"
        )

      refute html =~ "modal-open"
    end
  end

  describe "variables step rendering edge cases" do
    test "renders Unicode variable names without crashing" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "Café Report"},
          variables: [
            %{name: "客户_名称", label: "Client Name", type: :text},
            %{name: "総合金額", label: "Total Amount", type: :currency}
          ],
          creating: false
        )

      assert html =~ "客户_名称"
      assert html =~ "総合金額"
    end

    test "renders multiline variable as textarea, others as input" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [
            %{name: "description", label: "Description", type: :multiline},
            %{name: "company", label: "Company", type: :text}
          ],
          creating: false
        )

      assert html =~ ~r/<textarea[^>]*name="var\[description\]"/
      assert html =~ ~r/<input[^>]*name="var\[company\]"/
    end

    test "renders very long template name without truncation in form value" do
      long_name = String.duplicate("a", 250)

      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => long_name},
          variables: [],
          creating: false
        )

      # The pre-filled doc_name field surfaces the full template name —
      # truncation belongs in the LV after submit, not in the modal.
      assert html =~ long_name
    end

    test "creating=true disables the submit button (server-side guard)" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [],
          creating: true
        )

      # `disabled={@creating}` and `phx-disable-with` together: the
      # client transition uses phx-disable-with text and the server-set
      # `disabled` attribute survives a re-render.
      assert html =~ ~r/type="submit"[^>]*disabled/
    end

    test "Cancel button does not have phx-disable-with (UI-state-only)" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [],
          creating: false
        )

      # Only async/destructive buttons need phx-disable-with. Cancel is
      # a pure UI-state toggle and doesn't.
      refute html =~ ~r/phx-click="modal_close"[^>]*phx-disable-with/
    end
  end

  describe "image variable picker" do
    test "image variable renders a 'Choose image' button" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [
            %{name: "logo", label: "Logo", type: :image, config: %{default_width_px: 400}}
          ],
          image_values: %{},
          creating: false
        )

      assert html =~ "phx-click=\"open_media_picker\""
      assert html =~ "phx-value-name=\"logo\""
      assert html =~ "Choose image"
    end

    test "image_list variable renders a 'Choose images' button" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [
            %{
              name: "photos",
              label: "Photos",
              type: :image_list,
              config: %{default_width_px: 400, separator: :newline, max_count: nil}
            }
          ],
          image_values: %{},
          creating: false
        )

      assert html =~ "phx-click=\"open_media_picker\""
      assert html =~ "phx-value-name=\"photos\""
      assert html =~ "Choose images"
    end

    test "image_list variable shows count badge when images are pre-filled" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [
            %{
              name: "photos",
              label: "Photos",
              type: :image_list,
              config: %{default_width_px: 400, separator: :newline, max_count: nil}
            }
          ],
          image_values: %{"photos" => %{"media_ids" => ["uuid-1", "uuid-2"]}},
          creating: false
        )

      assert html =~ "2"
    end

    test "image variable shows selected indicator when filled" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [
            %{name: "logo", label: "Logo", type: :image, config: %{default_width_px: 400}}
          ],
          image_values: %{"logo" => %{"media_id" => "some-uuid"}},
          creating: false
        )

      assert html =~ "selected"
    end
  end

  describe "template tiles" do
    alias PhoenixKitDocumentCreator.Test.ImageFixtures

    defp tile(thumbnail) do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [%{"id" => "tpl-1", "name" => "Tile"}],
          thumbnails: %{"tpl-1" => thumbnail},
          step: "choose"
        )

      [tile] = Regex.run(~r/<div style="width:100px;height:141px;[^"]*">\s*<img[^>]*>/, html)
      tile
    end

    test "a portrait template keeps the top-anchored cover crop in its fixed tile" do
      thumb = ImageFixtures.png_uri(1200, 1600)
      tile = tile(thumb)
      assert tile =~ ~s(src="#{thumb}")
      assert tile =~ "object-fit:cover;object-position:top"
      refute tile =~ "onload"
    end

    test "a landscape template is fitted whole in the same fixed tile" do
      tile = tile(ImageFixtures.png_uri(1600, 1200))
      assert tile =~ "object-fit:contain;object-position:center"
    end
  end
end
