defmodule PhoenixKitDocumentCreator.Web.Routes do
  @moduledoc """
  Admin route definitions for the Document Creator module.

  Provides sub-page routes (new/edit) for Categories and Types beyond the
  main tab route auto-generated from `admin_tabs/0`.
  """

  @doc "Admin routes for the shared live_session (localized, with /:locale prefix)."
  def admin_locale_routes do
    quote do
      live(
        "/admin/document-creator/categories/new",
        PhoenixKitDocumentCreator.Web.CategoryFormLive,
        :new,
        as: :doc_creator_category_new_localized
      )

      live(
        "/admin/document-creator/categories/:uuid/edit",
        PhoenixKitDocumentCreator.Web.CategoryFormLive,
        :edit,
        as: :doc_creator_category_edit_localized
      )

      live(
        "/admin/document-creator/categories/:category_uuid/types/new",
        PhoenixKitDocumentCreator.Web.TypeFormLive,
        :new,
        as: :doc_creator_type_new_localized
      )

      live(
        "/admin/document-creator/types/:uuid/edit",
        PhoenixKitDocumentCreator.Web.TypeFormLive,
        :edit,
        as: :doc_creator_type_edit_localized
      )
    end
  end

  @doc "Admin routes for the shared live_session (non-localized)."
  def admin_routes do
    quote do
      live(
        "/admin/document-creator/categories/new",
        PhoenixKitDocumentCreator.Web.CategoryFormLive,
        :new,
        as: :doc_creator_category_new
      )

      live(
        "/admin/document-creator/categories/:uuid/edit",
        PhoenixKitDocumentCreator.Web.CategoryFormLive,
        :edit,
        as: :doc_creator_category_edit
      )

      live(
        "/admin/document-creator/categories/:category_uuid/types/new",
        PhoenixKitDocumentCreator.Web.TypeFormLive,
        :new,
        as: :doc_creator_type_new
      )

      live(
        "/admin/document-creator/types/:uuid/edit",
        PhoenixKitDocumentCreator.Web.TypeFormLive,
        :edit,
        as: :doc_creator_type_edit
      )
    end
  end
end
