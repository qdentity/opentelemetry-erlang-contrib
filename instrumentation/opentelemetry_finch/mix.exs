defmodule OpentelemetryFinch.MixProject do
  use Mix.Project

  def project do
    [
      app: :opentelemetry_finch,
      version: "0.1.0",
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:telemetry, "~> 0.4 or ~> 1.1.0"},
      {:opentelemetry_api, "~> 1.0"},
      {:bypass, "~> 2.1", only: :test},
      {:opentelemetry_telemetry, "~> 1.0.0"},
      {:opentelemetry_exporter, "~> 1.0", only: [:dev, :test]},
      {:opentelemetry, "~> 1.0", only: [:dev, :test]},
      {:finch, github: "sneako/finch"},
      {:ex_doc, "~> 0.28.3", only: [:dev], runtime: false}
    ]
  end
end
