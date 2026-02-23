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
  - Reserved run options are forwarded to `mix workflow.run`:
    - `-run-id`
    - `-backend`
    - `-source`
    - `-bus`
    - `-timeout`
    - `-start-app` (true/false)
    - `-await-completion` (true/false)
    - `-pretty` (true/false)
  - All non-reserved option pairs are converted into `--inputs` JSON.
  """

  @run_option_keys [
    "run_id",
    "backend",
    "source",
    "bus",
    "timeout",
    "start_app",
    "await_completion",
    "pretty"
  ]

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
    with {:ok, option_pairs} <- parse_option_pairs(option_tokens),
         {:ok, task_args} <- build_workflow_run_args(workflow_id, option_pairs) do
      {:ok, "workflow.run", task_args}
    else
      {:error, _reason} ->
        {:error, :invalid_option_pairs}
    end
  end

  defp build_workflow_run_args(workflow_id, option_pairs) do
    {run_options, inputs} = partition_option_pairs(option_pairs)

    with {:ok, run_option_args} <- encode_run_option_args(run_options),
         {:ok, input_args} <- encode_input_args(inputs) do
      {:ok, [workflow_id] ++ run_option_args ++ input_args}
    end
  end

  defp partition_option_pairs(option_pairs) do
    Enum.reduce(option_pairs, {%{}, %{}}, fn {key, value}, {run_options, inputs} ->
      if key in @run_option_keys do
        {Map.put(run_options, key, value), inputs}
      else
        {run_options, Map.put(inputs, key, value)}
      end
    end)
  end

  defp encode_input_args(inputs) when map_size(inputs) == 0, do: {:ok, []}
  defp encode_input_args(inputs), do: {:ok, ["--inputs", Jason.encode!(inputs)]}

  defp encode_run_option_args(run_options) do
    with {:ok, args} <- maybe_append_binary_option([], "--run-id", run_options["run_id"]),
         {:ok, args} <- maybe_append_backend_option(args, run_options["backend"]),
         {:ok, args} <- maybe_append_binary_option(args, "--source", run_options["source"]),
         {:ok, args} <- maybe_append_binary_option(args, "--bus", run_options["bus"]),
         {:ok, args} <- maybe_append_timeout_option(args, run_options["timeout"]),
         {:ok, args} <- maybe_append_boolean_option(args, "start-app", run_options["start_app"]),
         {:ok, args} <-
           maybe_append_boolean_option(args, "await-completion", run_options["await_completion"]) do
      maybe_append_boolean_option(args, "pretty", run_options["pretty"])
    end
  end

  defp maybe_append_binary_option(args, _option_name, nil), do: {:ok, args}

  defp maybe_append_binary_option(args, option_name, value) when is_binary(value) do
    normalized = String.trim(value)

    if normalized == "",
      do: {:error, :invalid_option_value},
      else: {:ok, args ++ [option_name, normalized]}
  end

  defp maybe_append_binary_option(_args, _option_name, _value),
    do: {:error, :invalid_option_value}

  defp maybe_append_backend_option(args, nil), do: {:ok, args}

  defp maybe_append_backend_option(args, value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "direct" -> {:ok, args ++ ["--backend", "direct"]}
      "strategy" -> {:ok, args ++ ["--backend", "strategy"]}
      _other -> {:error, :invalid_backend}
    end
  end

  defp maybe_append_backend_option(_args, _value), do: {:error, :invalid_backend}

  defp maybe_append_timeout_option(args, nil), do: {:ok, args}

  defp maybe_append_timeout_option(args, value) when is_binary(value) do
    normalized = String.trim(value)

    case Integer.parse(normalized) do
      {timeout_ms, ""} when timeout_ms > 0 ->
        {:ok, args ++ ["--timeout", Integer.to_string(timeout_ms)]}

      _other ->
        {:error, :invalid_timeout}
    end
  end

  defp maybe_append_timeout_option(_args, _value), do: {:error, :invalid_timeout}

  defp maybe_append_boolean_option(args, _flag, nil), do: {:ok, args}

  defp maybe_append_boolean_option(args, flag, value) when is_binary(value) do
    case parse_boolean_value(value) do
      {:ok, true} -> {:ok, args ++ ["--#{flag}"]}
      {:ok, false} -> {:ok, args ++ ["--no-#{flag}"]}
      {:error, _reason} -> {:error, :invalid_boolean}
    end
  end

  defp maybe_append_boolean_option(_args, _flag, _value), do: {:error, :invalid_boolean}

  defp parse_boolean_value(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      "1" -> {:ok, true}
      "0" -> {:ok, false}
      _other -> {:error, :invalid_boolean}
    end
  end

  defp parse_option_pairs(option_tokens), do: do_parse_option_pairs(option_tokens, [])

  defp do_parse_option_pairs([], option_pairs), do: {:ok, Enum.reverse(option_pairs)}

  defp do_parse_option_pairs([_option_without_value], _option_pairs),
    do: {:error, :missing_option_value}

  defp do_parse_option_pairs([option, value | rest], option_pairs) do
    with {:ok, input_key} <- parse_input_key(option) do
      do_parse_option_pairs(rest, [{input_key, value} | option_pairs])
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
