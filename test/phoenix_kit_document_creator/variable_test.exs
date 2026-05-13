defmodule PhoenixKitDocumentCreator.VariableTest do
  use ExUnit.Case, async: true

  describe "struct shape" do
    test "variable has a config map, defaulting to empty" do
      v = %PhoenixKitDocumentCreator.Variable{name: "x", label: "X", type: :text}
      assert v.config == %{}
    end

    test "image and image_list are valid types" do
      for t <- [:image, :image_list] do
        assert %PhoenixKitDocumentCreator.Variable{name: "x", label: "X", type: t}.type == t
      end
    end
  end

  describe "extract_string_variables/1" do
    test "extracts plain text variables" do
      text = "Hello {{ name }} and {{ company }}"

      assert PhoenixKitDocumentCreator.Variable.extract_string_variables(text) ==
               ["company", "name"]
    end

    test "deliberately ignores {{ image: x }} tokens" do
      text = "Logo: {{ image: logo }} and name {{ name }}"
      assert PhoenixKitDocumentCreator.Variable.extract_string_variables(text) == ["name"]
    end

    test "deliberately ignores {{ images: x }} tokens" do
      text = "Gallery: {{ images: photos }} and name {{ name }}"
      assert PhoenixKitDocumentCreator.Variable.extract_string_variables(text) == ["name"]
    end

    test "returns [] for non-binary input" do
      assert PhoenixKitDocumentCreator.Variable.extract_string_variables(:atom) == []
    end
  end

  describe "extract_image_variables/1" do
    test "captures single-image and list-image tags" do
      text = """
      Logo: {{ image: logo }}
      Photos: {{ images: photos }}
      Plain: {{ name }}
      Duplicate: {{ image: logo }}
      """

      assert PhoenixKitDocumentCreator.Variable.extract_image_variables(text) == [
               %{name: "logo", kind: :image},
               %{name: "photos", kind: :image_list}
             ]
    end

    test "tolerates whitespace variations" do
      text = "{{image:a}} {{  images :  b  }}"

      assert PhoenixKitDocumentCreator.Variable.extract_image_variables(text) == [
               %{name: "a", kind: :image},
               %{name: "b", kind: :image_list}
             ]
    end

    test "returns [] for non-binary input" do
      assert PhoenixKitDocumentCreator.Variable.extract_image_variables(nil) == []
    end
  end

  describe "extract_variables/1 (fork)" do
    test "returns string and image variables separately" do
      text = """
      {{ client_name }} {{ image: logo }} {{ name }} {{ images: photos }}
      """

      assert PhoenixKitDocumentCreator.Variable.extract_variables(text) == %{
               text: ["client_name", "name"],
               image: [
                 %{name: "logo", kind: :image},
                 %{name: "photos", kind: :image_list}
               ]
             }
    end

    test "returns empty fork for empty text" do
      assert PhoenixKitDocumentCreator.Variable.extract_variables("") ==
               %{text: [], image: []}
    end

    test "returns empty fork for non-binary" do
      assert PhoenixKitDocumentCreator.Variable.extract_variables(nil) ==
               %{text: [], image: []}
    end
  end

  describe "default_image_config/1" do
    test "includes opacity and z_index for :image" do
      cfg = PhoenixKitDocumentCreator.Variable.default_image_config(:image)
      assert cfg.opacity == 1.0
      assert cfg.z_index == 0
      assert cfg.default_width_px == 400
    end

    test "includes opacity and z_index for :image_list" do
      cfg = PhoenixKitDocumentCreator.Variable.default_image_config(:image_list)
      assert cfg.opacity == 1.0
      assert cfg.z_index == 0
      assert cfg.default_width_px == 400
      assert cfg.separator == :newline
      assert cfg.max_count == nil
    end
  end

  describe "build_definitions/1" do
    test "builds text variables with empty config" do
      fork = %{text: ["client_name"], image: []}

      assert [
               %PhoenixKitDocumentCreator.Variable{
                 name: "client_name",
                 type: :text,
                 config: %{}
               }
             ] = PhoenixKitDocumentCreator.Variable.build_definitions(fork)
    end

    test "builds image variable with default config" do
      fork = %{text: [], image: [%{name: "logo", kind: :image}]}

      assert [
               %PhoenixKitDocumentCreator.Variable{
                 name: "logo",
                 label: "Logo",
                 type: :image,
                 config: %{default_width_px: 400, opacity: 1.0, z_index: 0}
               }
             ] = PhoenixKitDocumentCreator.Variable.build_definitions(fork)
    end

    test "builds image_list variable with default config" do
      fork = %{text: [], image: [%{name: "photos", kind: :image_list}]}

      assert [
               %PhoenixKitDocumentCreator.Variable{
                 name: "photos",
                 type: :image_list,
                 config: %{
                   default_width_px: 400,
                   opacity: 1.0,
                   z_index: 0,
                   separator: :newline,
                   max_count: nil
                 }
               }
             ] = PhoenixKitDocumentCreator.Variable.build_definitions(fork)
    end

    test "preserves order: text first (alpha), then image (alpha)" do
      fork = %{
        text: ["b_text", "a_text"],
        image: [
          %{name: "b_img", kind: :image},
          %{name: "a_img", kind: :image_list}
        ]
      }

      names = PhoenixKitDocumentCreator.Variable.build_definitions(fork) |> Enum.map(& &1.name)
      assert names == ["a_text", "b_text", "a_img", "b_img"]
    end
  end
end
