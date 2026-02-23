defmodule Mix.Tasks.Workflow.Command do
  @shortdoc "Trigger workflow manual commands from the terminal"

  @moduledoc """
  Terminal wrapper for manual workflow trigger commands.

  This task publishes `workflow.trigger.manual.requested` and delegates
  publishing/response handling to `mix workflow.signal`.

  ## Examples

      mix workflow.command /workflow:review --workflow-id code_review
      mix workflow.command /workflow:review --params '{"value":"hello"}'

  ## Shared Options

  - `--workflow-id`
  - `--params` (JSON object)
  - `--source`
  - `--bus`
  - `--timeout`
  - `--no-start-app`
  - `--no-pretty`
  """

  use Mix.Task

  alias Mix.Tasks.Workflow.Signal, as: SignalTask

  @switches [
    workflow_id: :string,
    params: :string,
    source: :string,
    bus: :string,
    timeout: :integer,
    start_app: :boolean,
    pretty: :boolean
  ]

  @aliases [w: :workflow_id, p: :params, s: :source, b: :bus, t: :timeout]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if invalid != [] do
      invalid_flags =
        Enum.map_join(invalid, ", ", fn
          {key, _value} -> "--#{key}"
          key when is_atom(key) -> "--#{key}"
        end)

      Mix.raise("Unknown options: #{invalid_flags}")
    end

    command = parse_command(positional)
    workflow_id = normalize_optional_binary(Keyword.get(opts, :workflow_id, nil))
    params = parse_optional_json_map(Keyword.get(opts, :params, nil), "--params")

    payload =
      %{"command" => command}
      |> maybe_put("workflow_id", workflow_id)
      |> maybe_put("params", params)

    signal_args = build_signal_args("workflow.trigger.manual.requested", payload, opts)
    SignalTask.run(signal_args)
  end

  defp parse_command([command | tail]) when is_binary(command) do
    ensure_no_positional!(tail)

    command
    |> String.trim()
    |> case do
      "" -> Mix.raise("A command positional argument is required")
      normalized -> normalized
    end
  end

  defp parse_command(_args), do: Mix.raise("Usage: mix workflow.command <command> [options]")

  defp build_signal_args(signal_type, payload, opts) do
    data_json = Jason.encode!(payload)

    [signal_type, "--data", data_json]
    |> maybe_append_option("--source", normalize_optional_binary(Keyword.get(opts, :source, nil)))
    |> maybe_append_option("--bus", normalize_optional_binary(Keyword.get(opts, :bus, nil)))
    |> maybe_append_option(
      "--timeout",
      normalize_optional_positive_integer(Keyword.get(opts, :timeout, nil), "--timeout")
    )
    |> maybe_append_flag("--no-start-app", Keyword.get(opts, :start_app, true) == false)
    |> maybe_append_flag("--no-pretty", Keyword.get(opts, :pretty, true) == false)
  end

  defp maybe_append_option(args, _key, nil), do: args

  defp maybe_append_option(args, key, value) when is_integer(value) do
    args ++ [key, Integer.to_string(value)]
  end

  defp maybe_append_option(args, key, value) when is_binary(value) do
    args ++ [key, value]
  end

  defp maybe_append_flag(args, _flag, false), do: args
  defp maybe_append_flag(args, flag, true), do: args ++ [flag]

  defp ensure_no_positional!([]), do: :ok

  defp ensure_no_positional!(extra) do
    Mix.raise("Unexpected positional arguments: #{Enum.join(extra, ", ")}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_optional_binary(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_binary(_value), do: nil

  defp normalize_optional_positive_integer(nil, _option), do: nil

  defp normalize_optional_positive_integer(value, _option) when is_integer(value) and value > 0 do
    value
  end

  defp normalize_optional_positive_integer(_value, option) do
    Mix.raise("#{option} must be a positive integer")
  end

  defp parse_optional_json_map(nil, _option), do: nil

  defp parse_optional_json_map(value, option) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      json ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) ->
            map

          {:ok, _other} ->
            Mix.raise("#{option} must decode to a JSON object")

          {:error, reason} ->
            Mix.raise("#{option} must be valid JSON: #{Exception.message(reason)}")
        end
    end
  end
end
