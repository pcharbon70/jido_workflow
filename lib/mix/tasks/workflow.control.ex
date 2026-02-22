defmodule Mix.Tasks.Workflow.Control do
  @shortdoc "Control workflow runs from the terminal"

  @moduledoc """
  High-level terminal wrapper for workflow command signals.

  This task translates run-control actions to `workflow.*.requested` signals and
  delegates publishing/response handling to `mix workflow.signal`.

  ## Actions

      mix workflow.control pause <run_id>
      mix workflow.control resume <run_id>
      mix workflow.control cancel <run_id> [--reason <reason>]
      mix workflow.control step <run_id>
      mix workflow.control mode <run_id> --mode <auto|step>
      mix workflow.control get <run_id>
      mix workflow.control list [--workflow-id <id>] [--status <status>] [--limit <n>]
      mix workflow.control runtime-status
      mix workflow.control definitions [--include-disabled <true|false>] [--include-invalid <true|false>] [--limit <n>]
      mix workflow.control definition <workflow_id>
      mix workflow.control registry-refresh
      mix workflow.control registry-reload <workflow_id>
      mix workflow.control trigger-refresh
      mix workflow.control trigger-sync
      mix workflow.control trigger-runtime-status
      mix workflow.control trigger-manual [--trigger-id <id> | --command <command>] [--workflow-id <id>] [--params <json-map>]

  ## Shared Options

  - `--source`
  - `--bus`
  - `--timeout`
  - `--no-start-app`
  - `--no-pretty`
  """

  use Mix.Task

  alias Mix.Tasks.Workflow.Signal, as: SignalTask

  @switches [
    reason: :string,
    mode: :string,
    workflow_id: :string,
    status: :string,
    limit: :integer,
    include_disabled: :string,
    include_invalid: :string,
    trigger_id: :string,
    command: :string,
    params: :string,
    source: :string,
    bus: :string,
    timeout: :integer,
    start_app: :boolean,
    pretty: :boolean
  ]

  @aliases [r: :reason, m: :mode, w: :workflow_id, l: :limit, s: :source, b: :bus, t: :timeout]

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

    {signal_type, payload} = parse_action(positional, opts)
    signal_args = build_signal_args(signal_type, payload, opts)

    SignalTask.run(signal_args)
  end

  defp parse_action([action | tail], opts) when is_binary(action) do
    action
    |> normalize_action()
    |> parse_action_command(tail, opts)
  end

  defp parse_action(_args, _opts) do
    Mix.raise("Usage: mix workflow.control <action> [args] [options]")
  end

  defp parse_action_command("pause", tail, _opts) do
    {"workflow.run.pause.requested", %{"run_id" => parse_run_id(tail, "pause")}}
  end

  defp parse_action_command("resume", tail, _opts) do
    {"workflow.run.resume.requested", %{"run_id" => parse_run_id(tail, "resume")}}
  end

  defp parse_action_command("cancel", tail, opts) do
    run_id = parse_run_id(tail, "cancel")

    payload =
      %{"run_id" => run_id}
      |> maybe_put("reason", normalize_optional_binary(Keyword.get(opts, :reason, nil)))

    {"workflow.run.cancel.requested", payload}
  end

  defp parse_action_command("step", tail, _opts) do
    {"workflow.run.step.requested", %{"run_id" => parse_run_id(tail, "step")}}
  end

  defp parse_action_command("mode", tail, opts) do
    run_id = parse_run_id(tail, "mode")
    mode = parse_mode!(Keyword.get(opts, :mode, nil))
    {"workflow.run.mode.requested", %{"run_id" => run_id, "mode" => mode}}
  end

  defp parse_action_command("get", tail, _opts) do
    {"workflow.run.get.requested", %{"run_id" => parse_run_id(tail, "get")}}
  end

  defp parse_action_command("list", tail, opts) do
    ensure_no_positional!(tail, "list")

    payload =
      %{}
      |> maybe_put(
        "workflow_id",
        normalize_optional_binary(Keyword.get(opts, :workflow_id, nil))
      )
      |> maybe_put("status", normalize_optional_binary(Keyword.get(opts, :status, nil)))
      |> maybe_put(
        "limit",
        normalize_optional_positive_integer(Keyword.get(opts, :limit, nil), "--limit")
      )

    {"workflow.run.list.requested", payload}
  end

  defp parse_action_command(action, tail, opts)
       when action in ["definitions", "definition-list"] do
    ensure_no_positional!(tail, action)

    payload =
      %{}
      |> maybe_put(
        "include_disabled",
        normalize_optional_boolean(
          Keyword.get(opts, :include_disabled, nil),
          "--include-disabled"
        )
      )
      |> maybe_put(
        "include_invalid",
        normalize_optional_boolean(Keyword.get(opts, :include_invalid, nil), "--include-invalid")
      )
      |> maybe_put(
        "limit",
        normalize_optional_positive_integer(Keyword.get(opts, :limit, nil), "--limit")
      )

    {"workflow.definition.list.requested", payload}
  end

  defp parse_action_command(action, tail, _opts)
       when action in ["definition", "definition-get"] do
    {"workflow.definition.get.requested", %{"workflow_id" => parse_workflow_id(tail, action)}}
  end

  defp parse_action_command("registry-refresh", tail, _opts) do
    ensure_no_positional!(tail, "registry-refresh")
    {"workflow.registry.refresh.requested", %{}}
  end

  defp parse_action_command("registry-reload", tail, _opts) do
    {"workflow.registry.reload.requested",
     %{"workflow_id" => parse_workflow_id(tail, "registry-reload")}}
  end

  defp parse_action_command("trigger-refresh", tail, _opts) do
    ensure_no_positional!(tail, "trigger-refresh")
    {"workflow.trigger.refresh.requested", %{}}
  end

  defp parse_action_command("trigger-sync", tail, _opts) do
    ensure_no_positional!(tail, "trigger-sync")
    {"workflow.trigger.sync.requested", %{}}
  end

  defp parse_action_command(action, tail, _opts)
       when action in ["trigger-runtime-status", "trigger-status"] do
    ensure_no_positional!(tail, action)
    {"workflow.trigger.runtime.status.requested", %{}}
  end

  defp parse_action_command("trigger-manual", tail, opts) do
    ensure_no_positional!(tail, "trigger-manual")

    trigger_id = normalize_optional_binary(Keyword.get(opts, :trigger_id, nil))
    command = normalize_optional_binary(Keyword.get(opts, :command, nil))
    workflow_id = normalize_optional_binary(Keyword.get(opts, :workflow_id, nil))
    params = parse_optional_json_map(Keyword.get(opts, :params, nil), "--params")

    if is_nil(trigger_id) and is_nil(command) do
      Mix.raise("trigger-manual requires one of: --trigger-id, --command")
    end

    payload =
      %{}
      |> maybe_put("trigger_id", trigger_id)
      |> maybe_put("command", command)
      |> maybe_put("workflow_id", workflow_id)
      |> maybe_put("params", params)

    {"workflow.trigger.manual.requested", payload}
  end

  defp parse_action_command(action, tail, _opts) when action in ["runtime-status", "status"] do
    ensure_no_positional!(tail, action)
    {"workflow.runtime.status.requested", %{}}
  end

  defp parse_action_command(other, _tail, _opts), do: Mix.raise("Unknown action: #{other}")

  defp parse_run_id([run_id | tail], action) when is_binary(run_id) do
    ensure_no_positional!(tail, action)

    run_id
    |> String.trim()
    |> case do
      "" -> Mix.raise("<run_id> is required for #{action}")
      normalized -> normalized
    end
  end

  defp parse_run_id(_tail, action), do: Mix.raise("<run_id> is required for #{action}")

  defp parse_workflow_id([workflow_id | tail], action) when is_binary(workflow_id) do
    ensure_no_positional!(tail, action)

    workflow_id
    |> String.trim()
    |> case do
      "" -> Mix.raise("<workflow_id> is required for #{action}")
      normalized -> normalized
    end
  end

  defp parse_workflow_id(_tail, action), do: Mix.raise("<workflow_id> is required for #{action}")

  defp parse_mode!(nil), do: Mix.raise("--mode is required when action is mode")

  defp parse_mode!(mode) when is_binary(mode) do
    case String.trim(String.downcase(mode)) do
      "auto" -> "auto"
      "step" -> "step"
      "" -> Mix.raise("--mode is required when action is mode")
      other -> Mix.raise("--mode must be one of: auto, step (got: #{other})")
    end
  end

  defp parse_mode!(_mode), do: Mix.raise("--mode must be a string value")

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

  defp ensure_no_positional!([], _action), do: :ok

  defp ensure_no_positional!(extra, action) do
    Mix.raise("Unexpected positional arguments for #{action}: #{Enum.join(extra, ", ")}")
  end

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

  defp normalize_optional_boolean(nil, _option), do: nil
  defp normalize_optional_boolean(value, _option) when is_boolean(value), do: value

  defp normalize_optional_boolean(value, option) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "" -> Mix.raise("#{option} must be one of: true, false")
      "true" -> true
      "false" -> false
      "1" -> true
      "0" -> false
      _ -> Mix.raise("#{option} must be one of: true, false")
    end
  end

  defp normalize_optional_boolean(_value, option) do
    Mix.raise("#{option} must be one of: true, false")
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

  defp parse_optional_json_map(_value, option) do
    Mix.raise("#{option} must be a JSON string")
  end

  defp normalize_action(action) do
    action
    |> String.trim()
    |> String.downcase()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
