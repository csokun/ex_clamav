defmodule ClamavEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :clamav_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_make, "~> 0.9.0", runtime: false}
    ]
  end

  defp package do
    [
      name: "clamav_ex",
      files: ["lib", "native", "mix.exs", "README.md", "Makefile"],
      maintainers: ["Sokun Chorn"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/csokun/clamav_ex"}
    ]
  end
end
