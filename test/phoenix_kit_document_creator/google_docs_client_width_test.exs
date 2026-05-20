defmodule PhoenixKitDocumentCreator.GoogleDocsClientWidthTest do
  use ExUnit.Case, async: true
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  describe "content_width_pt/1" do
    test "default A4-ish page with default margins (72pt each side)" do
      doc = %{
        "documentStyle" => %{
          "pageSize" => %{"width" => %{"magnitude" => 612.0, "unit" => "PT"}},
          "marginLeft" => %{"magnitude" => 72.0, "unit" => "PT"},
          "marginRight" => %{"magnitude" => 72.0, "unit" => "PT"}
        }
      }

      assert GoogleDocsClient.content_width_pt(doc) == 468.0
    end

    test "falls back to 468pt when documentStyle missing" do
      assert GoogleDocsClient.content_width_pt(%{}) == 468.0
    end

    test "uses pageSize but missing margins → 72pt default each side" do
      doc = %{
        "documentStyle" => %{
          "pageSize" => %{"width" => %{"magnitude" => 595.0, "unit" => "PT"}}
        }
      }

      assert GoogleDocsClient.content_width_pt(doc) == 451.0
    end
  end

  describe "image_width_for_columns/2" do
    test "N=1 → full content width" do
      assert GoogleDocsClient.image_width_for_columns(468.0, 1) == 468.0
    end

    test "N=2 → half minus single gap" do
      # gap=8pt → (468 - 8)/2 = 230
      assert GoogleDocsClient.image_width_for_columns(468.0, 2) == 230.0
    end

    test "N=4 → quarter minus three gaps" do
      # (468 - 24)/4 = 111
      assert GoogleDocsClient.image_width_for_columns(468.0, 4) == 111.0
    end

    test "clamps N below 1 to 1" do
      assert GoogleDocsClient.image_width_for_columns(468.0, 0) == 468.0
    end

    test "clamps N above 4 to 4" do
      # (468 - 24)/4 = 111
      assert GoogleDocsClient.image_width_for_columns(468.0, 99) == 111.0
    end
  end
end
