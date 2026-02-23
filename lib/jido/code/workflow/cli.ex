defmodule Jido.Code.Workflow.CLI do
  @moduledoc """
  Command-line entrypoint for workflow operations.

  This module powers the `jido` escript so workflow commands can be executed
  without prefixing every invocation with `mix`.
  """

  @project_app :jido_workflow

  @usage """
  Usage:
    jido --workflow <workflow-name-without-a-slash> [-option-name option-value]...

  Notes:
  - `--workflow` must be the first argument for workflow CLI commands.
  - `<workflow-name-without-a-slash>` is passed as the `workflow_id` positional arg to `mix workflow.run`.
  - All options after the workflow name must be `-option-name option-value` pairs.
  - Each option pair is converted into `--inputs` JSON for `mix workflow.run`.
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
  def resolve(["--workflow" | rest]), do: resolve_workflow_run(rest)
  def resolve(_args), do: {:error, :workflow_prefix_required}

  defp resolve_workflow_run([]), do: {:error, :missing_workflow}

  defp resolve_workflow_run([workflow_id | option_tokens]) when is_binary(workflow_id) do
    normalized_workflow_id = String.trim(workflow_id)

    cond do
      normalized_workflow_id == "" ->
        {:error, :missing_workflow}

      String.starts_with?(normalized_workflow_id, "/") ->
        {:error, :invalid_workflow_name}

      true ->
        resolve_workflow_run_args(normalized_workflow_id, option_tokens)
    end
  end

  defp resolve_workflow_run_args(workflow_id, option_tokens) do
    case parse_option_pairs(option_tokens) do
      {:ok, inputs} when map_size(inputs) == 0 ->
        {:ok, "workflow.run", [workflow_id]}

      {:ok, inputs} ->
        {:ok, "workflow.run", [workflow_id, "--inputs", Jason.encode!(inputs)]}

      {:error, _reason} ->
        {:error, :invalid_option_pairs}
    end
  end

  defp parse_option_pairs(option_tokens), do: do_parse_option_pairs(option_tokens, %{})

  defp do_parse_option_pairs([], inputs), do: {:ok, inputs}

  defp do_parse_option_pairs([_option_without_value], _inputs),
    do: {:error, :missing_option_value}

  defp do_parse_option_pairs([option, value | rest], inputs) do
    with {:ok, input_key} <- parse_input_key(option) do
      do_parse_option_pairs(rest, Map.put(inputs, input_key, value))
    end
  end

  defp parse_input_key(option) when is_binary(option) do
    normalized = String.trim(option)

    cond do
      normalized == "" ->
        {:error, :invalid_option_key}

      not String.starts_with?(normalized, "-") ->
        {:error, :invalid_option_key}

      String.starts_with?(normalized, "--") ->
        {:error, :invalid_option_key}

      true ->
        key =
          normalized
          |> String.trim_leading("-")
          |> String.trim()
          |> String.downcase()
          |> String.replace("-", "_")

        if key == "", do: {:error, :invalid_option_key}, else: {:ok, key}
    end
  end

  defp parse_input_key(_option), do: {:error, :invalid_option_key}

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
