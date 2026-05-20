defmodule PhoenixKitDocumentCreator.GoogleDocsClientTableTest do
  use ExUnit.Case, async: true
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  describe "table_image_inserts/3 — phase A (table creation)" do
    test "returns a deleteContentRange + insertTable for placeholder range" do
      placeholder = %{start_index: 100, end_index: 120}
      media = [%{uri: "u1"}, %{uri: "u2"}, %{uri: "u3"}]
      opts = %{columns: 2, content_width_pt: 468.0}

      reqs = GoogleDocsClient.table_image_inserts(placeholder, media, opts)

      assert [
               %{"deleteContentRange" => %{"range" => %{"startIndex" => 100, "endIndex" => 120}}},
               %{"insertTable" => %{"rows" => 2, "columns" => 2, "location" => %{"index" => 100}}}
             ] = reqs
    end

    test "rows = ceil(count / columns)" do
      placeholder = %{start_index: 0, end_index: 10}
      media = List.duplicate(%{uri: "u"}, 5)
      opts = %{columns: 2, content_width_pt: 468.0}

      reqs = GoogleDocsClient.table_image_inserts(placeholder, media, opts)

      assert Enum.any?(
               reqs,
               &match?(
                 %{"insertTable" => %{"rows" => 3, "columns" => 2}},
                 &1
               )
             )
    end

    test "clamps columns to 1..4" do
      placeholder = %{start_index: 0, end_index: 10}
      media = [%{uri: "u"}]

      reqs =
        GoogleDocsClient.table_image_inserts(placeholder, media, %{
          columns: 99,
          content_width_pt: 468.0
        })

      assert Enum.any?(reqs, &match?(%{"insertTable" => %{"columns" => 4}}, &1))
    end
  end

  describe "fill_table_cells/3 — phase B (image insertion into cells)" do
    test "inserts one image per cell, left-to-right top-to-bottom" do
      # Mock the doc-after-table-creation: cells with known startIndices.
      # Each cell has a paragraph startIndex we insert into.
      cells = [
        %{insert_index: 200},
        %{insert_index: 220},
        %{insert_index: 240},
        %{insert_index: 260}
      ]

      media = [%{uri: "a"}, %{uri: "b"}, %{uri: "c"}]
      opts = %{image_width_pt: 230.0}

      reqs = GoogleDocsClient.fill_table_cells(cells, media, opts)

      uris = for %{"insertInlineImage" => %{"uri" => u}} <- reqs, do: u
      assert uris == ["c", "b", "a"], "insert last-first to avoid index drift"

      indices =
        for %{"insertInlineImage" => %{"location" => %{"index" => i}}} <-
              reqs,
            do: i

      # last-first by original cell order
      assert indices == [240, 220, 200]
    end

    test "ignores extra cells when media is shorter" do
      cells = [
        %{insert_index: 200},
        %{insert_index: 220},
        %{insert_index: 240},
        %{insert_index: 260}
      ]

      media = [%{uri: "a"}]
      reqs = GoogleDocsClient.fill_table_cells(cells, media, %{image_width_pt: 230.0})
      assert length(reqs) == 1
    end

    test "objectSize uses provided image_width_pt for width magnitude" do
      cells = [%{insert_index: 100}]
      media = [%{uri: "a"}]
      [req] = GoogleDocsClient.fill_table_cells(cells, media, %{image_width_pt: 230.0})
      assert get_in(req, ["insertInlineImage", "objectSize", "width", "magnitude"]) == 230.0
    end
  end
end
