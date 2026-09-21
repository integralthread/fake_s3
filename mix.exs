defmodule FakeS3.MixProject do
  use Mix.Project

  def project do
    [
      app: :fake_s3,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.16"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:mime, "~> 2.0"},
      {:xml_builder, "~> 2.2"},
      {:req, "~> 0.5", only: :test},
      {:req_s3, "~> 0.2.3", only: :test},
      {:ex_aws, "~> 2.7", only: :test},
      {:ex_aws_s3, "~> 2.5", only: :test},
      {:sweet_xml, "~> 0.7", only: :test},
      {:bedrock, "~> 0.7.2", only: :test, runtime: false}
    ]
  end
end
