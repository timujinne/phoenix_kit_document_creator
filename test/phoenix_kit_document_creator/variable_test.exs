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
end
