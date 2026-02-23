defmodule Jido.Code.Workflow.CLI do
  @moduledoc """
  Command-line entrypoint for workflow operations.

  This module powers the `jido` escript so workflow commands can be executed
  without prefixing every invocation with `mix`.
  """

  @project_app :jido_workflow

  @usage """
  Usage:
    jido --workflow /workflow:command [options]
    jido --workflow command <command> [options]
    jido --workflow run <workflow_id> [options]
    jido --workflow control <action> [args] [options]
    jido --workflow signal <signal_type> [options]
    jido --workflow watch [options]

  Notes:
  - `--workflow` must be the first argument for workflow CLI commands.
  - After `--workflow`, if the next argument starts with "/", it is treated as a manual workflow command.
  - `jido --workflow workflow <subcommand> ...` is also supported.
  """

  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    Mix.start()

    case resolve(args) do
      {:ok, task, task_args} ->
        run_task(task, task_args)

      {:error, _reason} ->
        Mix.shell().error(@usage)
        System.halt(1)
    end
  end

  @spec resolve([String.t()]) :: {:ok, String.t(), [String.t()]} | {:error, atom()}
  def resolve([]), do: {:error, :missing_command}
  def resolve([value]) when value in ["help", "--help", "-h"], do: {:error, :help}
  def resolve([value | _rest]) when value in ["help", "--help", "-h"], do: {:error, :help}
  def resolve(["--workflow" | rest]), do: resolve_workflow(rest)
  def resolve(_args), do: {:error, :workflow_prefix_required}

  defp resolve_workflow([]), do: {:error, :missing_command}

  defp resolve_workflow([command | rest]) when is_binary(command) do
    normalized = String.trim(command)

    cond do
      normalized == "" ->
        {:error, :missing_command}

      String.starts_with?(normalized, "/") ->
        {:ok, "workflow.command", [normalized | rest]}

      true ->
        resolve_named([String.downcase(normalized) | rest])
    end
  end

  defp resolve_named([]), do: {:error, :missing_command}
  defp resolve_named(["workflow" | rest]), do: resolve_named(rest)
  defp resolve_named([value]) when value in ["help", "--help", "-h"], do: {:error, :help}
  defp resolve_named([value | _rest]) when value in ["help", "--help", "-h"], do: {:error, :help}
  defp resolve_named(["command" | rest]), do: {:ok, "workflow.command", rest}
  defp resolve_named(["run" | rest]), do: {:ok, "workflow.run", rest}
  defp resolve_named(["control" | rest]), do: {:ok, "workflow.control", rest}
  defp resolve_named(["signal" | rest]), do: {:ok, "workflow.signal", rest}
  defp resolve_named(["watch" | rest]), do: {:ok, "workflow.watch", rest}
  defp resolve_named(_args), do: {:error, :unknown_command}

  defp find_project_root(path) when is_binary(path) do
    current = Path.expand(path)
    mix_file = Path.join(current, "mix.exs")

    if File.exists?(mix_file) do
      {:ok, current}
    else
      parent = Path.dirname(current)

      if parent == current do
        {:error, :no_mix_project}
      else
        find_project_root(parent)
      end
    end
  end

  defp run_task(task, task_args) do
    case find_project_root(File.cwd!()) do
      {:ok, root} ->
        Mix.Project.in_project(@project_app, root, fn _ ->
          configure_tzdata_data_dir()
          Mix.Task.run(task, task_args)
        end)

      {:error, :no_mix_project} ->
        Mix.shell().error(
          "Could not locate a mix project (mix.exs) from #{File.cwd!()} or its parent directories"
        )

        System.halt(1)
    end
  end

  defp configure_tzdata_data_dir do
    data_dir =
      System.get_env("JIDO_WORKFLOW_TZDATA_DIR") ||
        Path.join(System.tmp_dir!(), "jido_workflow_tzdata")

    File.mkdir_p!(data_dir)
    Application.put_env(:tzdata, :data_dir, data_dir, persistent: true)
  end
end
