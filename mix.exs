defmodule FakeS3.MixProject do
  use Mix.Project

  def project do
    [
      app: :fake_s3,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {FakeS3.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.16"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:mime, "~> 2.0"},
      {:xml_builder, "~> 2.2"},
      {:req, "~> 0.5", only: :test},
      {:req_s3, "~> 0.2.3", only: :test}
    ]
  end
end
