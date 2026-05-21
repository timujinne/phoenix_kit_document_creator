defmodule PhoenixKitDocumentCreator.MixProject do
  use Mix.Project

  @version "0.4.2"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_document_creator"

  def project do
    [
      app: :phoenix_kit_document_creator,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Document Creator module for PhoenixKit — document templates and PDF generation via Google Docs",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit], ignore_warnings: ".dialyzer_ignore.exs"],

      # Coverage — exclude test-support modules (DataCase, TestRepo,
      # Test.Endpoint, Test.Router, etc.) so the percentage reflects
      # production-code coverage. The test-support modules ARE compiled
      # under elixirc_paths(:test) but they exist to drive the suite,
      # not to be tested themselves.
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitDocumentCreator\.Test\./,
          PhoenixKitDocumentCreator.DataCase,
          PhoenixKitDocumentCreator.LiveCase,
          PhoenixKitDocumentCreator.ActivityLogAssertions
        ]
      ],

      # Docs
      name: "PhoenixKitDocumentCreator",
      source_url: @source_url,
      docs: docs(),
      compilers: [:phoenix_kit_css_sources] ++ Mix.compilers()
    ]
  end

  def application do
    [extra_applications: [:logger, :gettext], mod: {PhoenixKitDocumentCreator.Application, []}]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "quality.ci"
      ]
    ]
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API.
      {:phoenix_kit, "~> 1.7"},

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.1"},

      # HTTP client for Google Docs/Drive API
      {:req, "~> 0.5"},

      # Gettext owns this module's i18n catalogues under priv/gettext/.
      # The parent app sets the user's locale per request; our backend
      # (PhoenixKitDocumentCreator.Gettext) looks up msgids independently.
      {:gettext, "~> 1.0"},

      # Code quality
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Test-only — `Phoenix.LiveViewTest` 1.1+ uses LazyHTML for parsing
      # rendered HTML; without this the LV smoke tests crash on import.
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitDocumentCreator",
      source_ref: @version
    ]
  end
end
