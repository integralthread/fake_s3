defmodule FakeS3.StorageError do
  defexception [:reason]

  @impl true
  def message(%{reason: reason}), do: "storage failure: #{inspect(reason)}"
end
