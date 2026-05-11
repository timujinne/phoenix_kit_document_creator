defmodule PhoenixKitDocumentCreator.GettextTest do
  use ExUnit.Case, async: true

  # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
  # release that pre-dates `PhoenixKit.Dashboard.Tab.localized_label/1`.
  # Once the consumer upgrades, the helper detects it and these tests
  # run automatically.
  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab

  test "PhoenixKitDocumentCreator.Gettext compiles and is a valid gettext backend" do
    assert Code.ensure_loaded?(PhoenixKitDocumentCreator.Gettext)
  end

  test "Tab.localized_label/1 returns Russian translation for Document Creator" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "ru")

    tab = %Tab{
      id: :admin_document_creator,
      label: "Document Creator",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Создание документов"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "Tab.localized_label/1 returns Estonian translation for Document Creator" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "et")

    tab = %Tab{
      id: :admin_document_creator,
      label: "Document Creator",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Dokumentide loomine"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "Tab.localized_label/1 translates child tab labels (Documents/Templates) in ru" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "ru")

    docs = %Tab{
      id: :admin_document_creator_documents,
      label: "Documents",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    templates = %Tab{
      id: :admin_document_creator_templates,
      label: "Templates",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(docs) == "Документы"
    assert Tab.localized_label(templates) == "Шаблоны"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "Tab.localized_label/1 translates child tab labels (Documents/Templates) in et" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "et")

    docs = %Tab{
      id: :admin_document_creator_documents,
      label: "Documents",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    templates = %Tab{
      id: :admin_document_creator_templates,
      label: "Templates",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(docs) == "Dokumendid"
    assert Tab.localized_label(templates) == "Mallid"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "Tab.localized_label/1 falls back to raw label when no gettext_backend set" do
    tab = %Tab{id: :admin_document_creator, label: "Document Creator"}
    assert Tab.localized_label(tab) == "Document Creator"
  end

  test "Tab.localized_label/1 falls back to msgid when translation is missing" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "ru")

    tab = %Tab{
      id: :admin_unknown,
      label: "This string has no translation",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "This string has no translation"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  # Real `admin_tabs/0` / `settings_tabs/0` output — catches config drift
  # if a Tab label is renamed in the module but the corresponding msgid
  # isn't updated in the .po files. The hand-constructed tests above
  # cover the helper's branching; these cover the wiring.
  test "real admin_tabs/0 labels translate via the configured backend (ru)" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "ru")

    labels = Map.new(PhoenixKitDocumentCreator.admin_tabs(), &{&1.id, Tab.localized_label(&1)})

    assert labels[:admin_document_creator] == "Создание документов"
    assert labels[:admin_document_creator_documents] == "Документы"
    assert labels[:admin_document_creator_templates] == "Шаблоны"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "real admin_tabs/0 labels translate via the configured backend (et)" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "et")

    labels = Map.new(PhoenixKitDocumentCreator.admin_tabs(), &{&1.id, Tab.localized_label(&1)})

    assert labels[:admin_document_creator] == "Dokumentide loomine"
    assert labels[:admin_document_creator_documents] == "Dokumendid"
    assert labels[:admin_document_creator_templates] == "Mallid"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "real settings_tabs/0 label translates via the configured backend (ru/et)" do
    [settings_tab] = PhoenixKitDocumentCreator.settings_tabs()

    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "ru")
    assert Tab.localized_label(settings_tab) == "Создание документов"

    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "et")
    assert Tab.localized_label(settings_tab) == "Dokumentide loomine"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "every admin/settings tab carries the module's gettext_backend" do
    tabs = PhoenixKitDocumentCreator.admin_tabs() ++ PhoenixKitDocumentCreator.settings_tabs()

    for tab <- tabs do
      assert tab.gettext_backend == PhoenixKitDocumentCreator.Gettext,
             "Tab #{inspect(tab.id)} is missing gettext_backend wiring — " <>
               "labels won't translate at render time"
    end
  end
end
