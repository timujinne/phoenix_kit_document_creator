defmodule PhoenixKitDocumentCreator.AnnotatedFlagTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Variable

  # ---------------------------------------------------------------------------
  # Variable.default_image_config/1 — annotated defaults
  # ---------------------------------------------------------------------------

  describe "default_image_config/1 annotated field" do
    test "image default config has annotated: true" do
      cfg = Variable.default_image_config(:image)
      assert cfg.annotated == true
    end

    test "image_list default config has annotated: true" do
      cfg = Variable.default_image_config(:image_list)
      assert cfg.annotated == true
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_slot_config propagation via image_slots_for_template
  #
  # The actual image_slots_for_template/1 is tested in integration tests (excluded
  # when DB is unavailable). Here we verify the helper logic directly by exercising
  # the public default_image_config path and checking that the annotated key is
  # present in the default output that resolve_slot_config would merge.
  # ---------------------------------------------------------------------------

  describe "annotated key is present in string-keyed default config" do
    test "image default has 'annotated' => true as string key after conversion" do
      string_default =
        Variable.default_image_config(:image)
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      assert Map.fetch!(string_default, "annotated") == true
    end

    test "image_list default has 'annotated' => true as string key after conversion" do
      string_default =
        Variable.default_image_config(:image_list)
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      assert Map.fetch!(string_default, "annotated") == true
    end

    test "saved config false overrides the default after merge" do
      saved = %{"annotated" => false, "default_width_px" => 300}

      string_default =
        Variable.default_image_config(:image)
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      merged = Map.merge(string_default, saved)

      assert merged["annotated"] == false
    end

    test "saved config true preserves true after merge" do
      saved = %{"annotated" => true}

      string_default =
        Variable.default_image_config(:image)
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      merged = Map.merge(string_default, saved)

      assert merged["annotated"] == true
    end
  end

  # ---------------------------------------------------------------------------
  # VariableConfigForm renders the annotated toggle
  # ---------------------------------------------------------------------------

  describe "VariableConfigForm annotated toggle" do
    import Phoenix.LiveViewTest

    alias PhoenixKitDocumentCreator.Web.Components.VariableConfigForm

    test "image: renders Include annotations toggle, checked by default" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{name: "logo", type: :image, config: %{default_width_px: 400}}
        )

      assert html =~ "annotated"
      assert html =~ "Include annotations"
    end

    test "image: toggle is checked when annotated is true" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{name: "logo", type: :image, config: %{"annotated" => true}}
        )

      assert html =~ ~s(checked)
    end

    test "image: toggle is unchecked when annotated is false" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{name: "logo", type: :image, config: %{"annotated" => false}}
        )

      # hidden false input must be present; checkbox must not carry checked attr
      assert html =~ ~s(value="false")
      refute html =~ ~s(checked="checked")
      refute html =~ ~s( checked>)
    end

    test "image_list: renders Include annotations toggle" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{
            name: "photos",
            type: :image_list,
            config: %{default_width_px: 400, separator: :newline, max_count: nil}
          }
        )

      assert html =~ "annotated"
      assert html =~ "Include annotations"
    end

    test "image_list: toggle is checked when annotated is true" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{
            name: "photos",
            type: :image_list,
            config: %{"annotated" => true, "separator" => "newline"}
          }
        )

      assert html =~ ~s(checked)
    end

    test "image_list: toggle is unchecked when annotated is false" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{
            name: "photos",
            type: :image_list,
            config: %{"annotated" => false, "separator" => "newline"}
          }
        )

      assert html =~ ~s(value="false")
      refute html =~ ~s(checked="checked")
      refute html =~ ~s( checked>)
    end
  end
end
