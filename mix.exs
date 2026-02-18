defmodule ExClamav.MixProject do
  use Mix.Project

  @version "0.1.6"
  @repo_url "https://github.com/csokun/ex_clamav"

  def project do
    [
      app: :ex_clamav,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),

      # Hex
      package: package(),
      description: "Elixir wrapper for ClamAV",

      # Docs
      name: "ExClamav",
      docs: &docs/0
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_make, "~> 0.9.0", runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end

  defp package do
    [
      name: "ex_clamav",
      files: ["lib", "mix.exs", "README.md", "Makefile"],
      maintainers: ["Sokun Chorn"],
      licenses: ["GPL-2.0-only"],
      links: %{"GitHub" => "https://github.com/csokun/ex_clamav"}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @repo_url,
      extra_section: "GUIDES",
      formatters: ["html", "epub"],
      extras: [
        "guides/architecture.md",
        "README.md"
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end
end
