defmodule Kernel.ParallelRequire do
  @moduledoc """
  A module responsible for requiring files in parallel.
  """

  @doc """
  Requires the given files.

  A callback that will be invoked with each file, or a keyword list of `callbacks` can be provided:

    * `:each_file` - invoked with each file

    * `:each_module` - invoked with file, module name, and binary code

  Returns the modules generated by each required file.
  """
  def files(files, callbacks \\ [])

  def files(files, callback) when is_function(callback, 1) do
    files(files, [each_file: callback])
  end

  def files(files, callbacks) when is_list(callbacks) do
    compiler_pid = self()
    :elixir_code_server.cast({:reset_warnings, compiler_pid})
    schedulers = max(:erlang.system_info(:schedulers_online), 2)
    result = spawn_requires(files, [], callbacks, schedulers, [])

    # In case --warning-as-errors is enabled and there was a warning,
    # compilation status will be set to error.
    case :elixir_code_server.call({:compilation_status, compiler_pid}) do
      :ok ->
        result
      :error ->
        IO.puts :stderr, "\nExecution failed due to warnings while using the --warnings-as-errors option"
        exit({:shutdown, 1})
    end
  end

  defp spawn_requires([], [], _callbacks, _schedulers, result), do: result

  defp spawn_requires([], waiting, callbacks, schedulers, result) do
    wait_for_messages([], waiting, callbacks, schedulers, result)
  end

  defp spawn_requires(files, waiting, callbacks, schedulers, result) when length(waiting) >= schedulers do
    wait_for_messages(files, waiting, callbacks, schedulers, result)
  end

  defp spawn_requires([file | files], waiting, callbacks, schedulers, result) do
    parent = self()

    {pid, ref} = :erlang.spawn_monitor fn ->
      :erlang.put(:elixir_compiler_pid, parent)
      :erlang.put(:elixir_compiler_file, file)

      result =
        try do
          new = Code.require_file(file) || []
          {:required, Enum.map(new, &elem(&1, 0))}
        catch
          kind, reason ->
            {kind, reason, System.stacktrace}
        end

      send(parent, {:file_required, self(), file, result})
      exit(:shutdown)
    end

    spawn_requires(files, [{pid, ref} | waiting], callbacks, schedulers, result)
  end

  defp wait_for_messages(files, waiting, callbacks, schedulers, result) do
    receive do
      {:file_required, pid, file, {:required, mods}} ->
        discard_down(pid)
        if each_file_callback = callbacks[:each_file] do
          each_file_callback.(file)
        end
        waiting = List.keydelete(waiting, pid, 0)
        spawn_requires(files, waiting, callbacks, schedulers, mods ++ result)

      {:file_required, pid, _file, {kind, reason, stacktrace}} ->
        discard_down(pid)
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ref, :process, pid, reason} ->
        handle_down(waiting, pid, ref, reason)
        spawn_requires(files, waiting, callbacks, schedulers, result)

      {:module_available, child, ref, file, module, binary} ->
        if each_module_callback = callbacks[:each_module] do
          each_module_callback.(file, module, binary)
        end

        send(child, {ref, :ack})
        spawn_requires(files, waiting, callbacks, schedulers, result)

      {:struct_available, _} ->
        spawn_requires(files, waiting, callbacks, schedulers, result)

      {:waiting, _, child, ref, _, _} ->
        send(child, {ref, :not_found})
        spawn_requires(files, waiting, callbacks, schedulers, result)
    end
  end

  defp discard_down(pid) do
    receive do
      {:DOWN, _, :process, ^pid, _} -> :ok
    end
  end

  defp handle_down(waiting, pid, ref, reason) do
    if reason != :normal and {pid, ref} in waiting do
      :erlang.raise(:exit, reason, [])
    end
    :ok
  end
end
