defmodule PhoenixKitDocumentCreator.MixProject do
  use Mix.Project

  @version "0.9.3"
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
        # Run via `cmd` so Hex bootstraps in a fresh process — the hex.* archive
        # tasks aren't reliably resolvable through Mix.Task.run inside an alias.
        "cmd mix hex.audit",
        "quality.ci",
        # Run via `cmd` so the subprocess auto-selects MIX_ENV=test; a bare
        # "test" step inside an alias stays in :dev and aborts.
        "cmd mix test --warnings-as-errors"
      ]
    ]
  end

  # Swaps a Hex pin for a local checkout when PHOENIX_KIT_PATH is set, so this
  # module's suite can run against uncommitted core without publishing it.
  # Unset means the published pin, so `mix hex.publish` and CI are unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API — and, since
      # the `put_slug/3` adoption, the slug changeset glue as well.
      # 2.21.3+ is REQUIRED, not preferred. Two facts set the floor:
      #   - `Template.changeset/2` calls `PhoenixKit.Utils.Slug.put_slug/3`,
      #     which does not exist before core 2.4.0.
      #   - `Paths.integrations/0` links to `/admin/settings/integrations` as
      #     the WEBSITE-wide connections page. Core 2.4–2.18 served the personal
      #     page at that path, 2.19–2.21.2 served the website page under a
      #     `/website` segment, and only 2.21.3 renamed it to the bare path.
      # Under a looser floor a host resolves a core where the link lands on the
      # wrong page — in the consumer's app, never in this repo's own run,
      # because the workspace always resolves the newest core. Two-segment
      # `~> 2.21` plus a patch guard, so every later 2.x still satisfies it.
      pk_dep(:phoenix_kit, "~> 2.21 and >= 2.21.3"),

      # mdex_native (pulled in transitively through phoenix_kit's mdex dep)
      # builds from source when MDEX_NATIVE_BUILD=1 is set in the
      # environment; that path requires rustler itself, not just
      # rustler_precompiled. Same declaration as phoenix_kit's own mix.exs.
      {:rustler, ">= 0.0.0", optional: true},

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.2"},

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
      # Must match the release tag's form exactly, or every HexDocs source link
      # 404s. Tags were v-prefixed through v0.7.0 and are bare from 0.8.0 on.
      source_ref: @version
    ]
  end
end
