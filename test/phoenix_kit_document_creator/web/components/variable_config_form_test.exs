defmodule PhoenixKitDocumentCreator.Web.Components.VariableConfigFormTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitDocumentCreator.Web.Components.VariableConfigForm

  describe "image variable" do
    test "renders default_width_px input" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{name: "logo", type: :image, config: %{default_width_px: 400}}
        )

      assert html =~ "default_width_px"
      assert html =~ "400"
    end

    test "does not render separator or max_count fields" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{name: "logo", type: :image, config: %{default_width_px: 200}}
        )

      refute html =~ "separator"
      refute html =~ "max_count"
    end
  end

  describe "image_list variable" do
    test "renders default_width_px input" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{
            name: "photos",
            type: :image_list,
            config: %{default_width_px: 400, separator: :newline, max_count: nil}
          }
        )

      assert html =~ "default_width_px"
      assert html =~ "400"
    end

    test "renders separator select with current value" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{
            name: "photos",
            type: :image_list,
            config: %{default_width_px: 400, separator: :newline, max_count: nil}
          }
        )

      assert html =~ "separator"
      assert html =~ "newline"
    end

    test "renders max_count input" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{
            name: "photos",
            type: :image_list,
            config: %{default_width_px: 400, separator: :space, max_count: 5}
          }
        )

      assert html =~ "max_count"
      assert html =~ "5"
    end

    test "renders fit select defaulting to width" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{
            name: "photos",
            type: :image_list,
            config: %{default_width_px: 400, separator: :newline, max_count: nil}
          }
        )

      assert html =~ "config][fit]"
      assert html =~ ~r/<option value="width" selected[^>]*>/
    end

    test "renders fit select with page selected when config has fit: \"page\"" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{
            name: "photos",
            type: :image_list,
            config: %{default_width_px: 400, separator: :newline, max_count: nil, fit: "page"}
          }
        )

      assert html =~ ~r/<option value="page" selected[^>]*>/
    end
  end

  describe "non-image variable" do
    test "renders nothing for text variable" do
      html =
        render_component(&VariableConfigForm.config_form/1,
          variable: %{name: "client_name", type: :text, config: %{}}
        )

      assert html == ""
    end
  end
end
