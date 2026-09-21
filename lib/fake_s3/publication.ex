defmodule FakeS3.Publication do
  @moduledoc false

  # Undo journal for body + metadata publication. The router serializes all
  # access to this data directory, including recovery. No response is sent
  # until run/2 returns. A killed writer leaves a pending journal which is
  # restored before the next request (also after a VM restart).
  alias FakeS3.Config

  defp root, do: Path.join(Path.expand(Config.data_dir()), ".publications")

  def run(paths, fun) do
    File.mkdir_p!(root())
    id = FakeS3.Storage.unique_suffix()
    preparing = Path.join(root(), "preparing-" <> id)
    pending = Path.join(root(), "pending-" <> id)
    File.mkdir!(preparing)

    entries =
      paths
      |> Enum.with_index()
      |> Enum.map(fn {path, index} ->
        backup = Integer.to_string(index)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            File.cp!(path, Path.join(preparing, backup))
            sync!(Path.join(preparing, backup))
            %{path: Path.expand(path), backup: backup}

          {:error, :enoent} ->
            %{path: Path.expand(path), backup: nil}

          other ->
            raise FakeS3.StorageError, reason: {:cannot_snapshot, path, other}
        end
      end)

    File.write!(Path.join(preparing, "manifest.json"), Jason.encode!(entries), [:sync])
    File.rename!(preparing, pending)

    try do
      case fun.() do
        :ok ->
          commit!(pending, id)
          :ok

        {:ok, _} = result ->
          commit!(pending, id)
          result

        {:error, _} = error ->
          restore!(pending)
          error
      end
    rescue
      error ->
        restore_if_pending!(pending)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        restore_if_pending!(pending)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def recover! do
    # No request can be writing staging files while the root lock is held.
    File.rm_rf!(Path.join(Config.data_dir(), ".staging"))

    case File.ls(root()) do
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise FakeS3.StorageError, reason: {:journal_unreadable, reason}

      {:ok, entries} ->
        Enum.each(entries, fn name ->
          path = Path.join(root(), name)

          cond do
            String.starts_with?(name, "pending-") -> restore!(path)
            String.starts_with?(name, "preparing-") -> File.rm_rf!(path)
            String.starts_with?(name, "committed-") -> File.rm_rf!(path)
            true -> raise FakeS3.StorageError, reason: {:unknown_journal, name}
          end
        end)
    end
  end

  defp restore_if_pending!(pending) do
    # Once renamed to committed, publication must not be rolled back even if
    # journal cleanup fails. Recovery will finish that cleanup on the next call.
    case File.stat(pending) do
      {:error, :enoent} -> :ok
      {:ok, _} -> restore!(pending)
      {:error, reason} -> raise FakeS3.StorageError, reason: {:journal_unreadable, reason}
    end
  end

  defp commit!(pending, id) do
    committed = Path.join(root(), "committed-" <> id)
    File.rename!(pending, committed)
    File.rm_rf!(committed)
  end

  defp restore!(pending) do
    pending
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
    |> Enum.each(fn %{"path" => path, "backup" => backup} ->
      if backup do
        File.mkdir_p!(Path.dirname(path))
        staged = Path.join(pending, backup <> ".restore")
        File.cp!(Path.join(pending, backup), staged)
        File.rename!(staged, path)
      else
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> raise FakeS3.StorageError, reason: {:restore_failed, path, reason}
        end
      end
    end)

    File.rm_rf!(pending)
  end

  defp sync!(path) do
    {:ok, io} = File.open(path, [:read, :write, :binary])

    try do
      :ok = :file.sync(io)
    after
      File.close(io)
    end
  end
end
