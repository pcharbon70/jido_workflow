defmodule Mix.Tasks.Workflow.Run do
  @shortdoc "Start a workflow run from the terminal"

  @moduledoc """
  Convenience task for starting workflows through command signals.

  This task publishes `workflow.run.start.requested` and waits for
  `workflow.run.start.accepted` / `workflow.run.start.rejected`.
  By default it also waits for terminal run lifecycle events:

  - `workflow.run.completed`
  - `workflow.run.failed`
  - `workflow.run.cancelled`

  ## Examples

      mix workflow.run my_flow --inputs '{"value":"hello"}'
      mix workflow.run my_flow --inputs '{"value":"hello"}' --backend strategy
      mix workflow.run my_flow --inputs '{"value":"hello"}' --no-await-completion
  """

  use Mix.Task

  alias Jido.Code.Workflow.Broadcaster
  alias Jido.Signal
  alias Jido.Signal.Bus

  @switches [
    inputs: :string,
    run_id: :string,
    backend: :string,
    source: :string,
    bus: :string,
    timeout: :integer,
    start_app: :boolean,
    await_completion: :boolean,
    pretty: :boolean
  ]
  @aliases [i: :inputs, r: :run_id, b: :backend, s: :source, t: :timeout]

  @default_source "/mix/workflow.run"
  @default_timeout_ms 15_000
  @run_signal_patterns ["workflow.run.*", "workflow.run.start.*"]

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

    workflow_id = parse_workflow_id(positional)
    start_app? = Keyword.get(opts, :start_app, true)
    await_completion? = Keyword.get(opts, :await_completion, true)
    pretty? = Keyword.get(opts, :pretty, true)
    timeout_ms = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout_ms))
    source = parse_source(Keyword.get(opts, :source, @default_source))
    bus = parse_bus(Keyword.get(opts, :bus, nil))
    inputs = decode_inputs!(Keyword.get(opts, :inputs, "{}"))
    run_id = normalize_optional_binary(Keyword.get(opts, :run_id, nil))
    backend = normalize_backend(Keyword.get(opts, :backend, nil))

    if start_app? do
      Mix.Task.run("app.start")
    end

    request_payload =
      %{"workflow_id" => workflow_id, "inputs" => inputs}
      |> maybe_put("run_id", run_id)
      |> maybe_put("backend", backend)

    request_signal =
      Signal.new!("workflow.run.start.requested", request_payload, source: source)

    case subscribe_run_signal_patterns(bus) do
      {:ok, subscription_ids} ->
        try do
          with {:ok, _published} <- Bus.publish(bus, [request_signal]),
               {:ok, start_signal} <- await_start_response(request_signal.id, timeout_ms) do
            case start_signal.type do
              "workflow.run.start.rejected" ->
                print_json(
                  %{
                    "status" => "rejected",
                    "request" => serialize_signal(request_signal),
                    "start_response" => serialize_signal(start_signal)
                  },
                  pretty?
                )

                Mix.raise("Run start rejected")

              "workflow.run.start.accepted" ->
                handle_accepted_start(
                  start_signal,
                  request_signal,
                  await_completion?,
                  timeout_ms,
                  pretty?
                )
            end
          else
            {:error, :timeout} ->
              print_json(
                %{
                  "status" => "timeout",
                  "phase" => "start_response",
                  "request" => serialize_signal(request_signal),
                  "timeout_ms" => timeout_ms
                },
                pretty?
              )

              Mix.raise("Timed out waiting for run start response")

            {:error, reason} ->
              Mix.raise("Failed to start workflow run: #{inspect(reason)}")
          end
        after
          unsubscribe_all(bus, subscription_ids)
        end

      {:error, reason} ->
        Mix.raise("Failed to subscribe to run events: #{inspect(reason)}")
    end
  end

  defp handle_accepted_start(start_signal, request_signal, false, _timeout_ms, pretty?) do
    run_id = fetch(start_signal.data, "run_id")

    print_json(
      %{
        "status" => "accepted",
        "workflow_id" => fetch(start_signal.data, "workflow_id"),
        "run_id" => run_id,
        "request" => serialize_signal(request_signal),
        "start_response" => serialize_signal(start_signal)
      },
      pretty?
    )
  end

  defp handle_accepted_start(start_signal, request_signal, true, timeout_ms, pretty?) do
    run_id = fetch(start_signal.data, "run_id")

    if not valid_binary?(run_id) do
      Mix.raise("Start response did not include run_id")
    end

    case await_run_terminal_signal(run_id, timeout_ms) do
      {:ok, terminal_signal} ->
        status = terminal_status(terminal_signal.type)

        print_json(
          %{
            "status" => status,
            "workflow_id" => fetch(start_signal.data, "workflow_id"),
            "run_id" => run_id,
            "request" => serialize_signal(request_signal),
            "start_response" => serialize_signal(start_signal),
            "terminal_signal" => serialize_signal(terminal_signal)
          },
          pretty?
        )

        if status in ["failed", "cancelled"] do
          Mix.raise("Run finished with status #{status}")
        end

      {:error, :timeout} ->
        print_json(
          %{
            "status" => "timeout",
            "phase" => "run_completion",
            "run_id" => run_id,
            "request" => serialize_signal(request_signal),
            "start_response" => serialize_signal(start_signal),
            "timeout_ms" => timeout_ms
          },
          pretty?
        )

        Mix.raise("Timed out waiting for run completion")
    end
  end

  defp await_start_response(request_signal_id, timeout_ms) do
    started_at = now_ms()
    do_await_start_response(request_signal_id, timeout_ms, started_at)
  end

  defp do_await_start_response(request_signal_id, timeout_ms, started_at) do
    case remaining_timeout(timeout_ms, started_at) do
      :timeout ->
        {:error, :timeout}

      remaining ->
        receive do
          {:signal, %Signal{type: "workflow.run.start.accepted"} = signal} ->
            if start_response_matches_request?(signal, request_signal_id) do
              {:ok, signal}
            else
              do_await_start_response(request_signal_id, timeout_ms, started_at)
            end

          {:signal, %Signal{type: "workflow.run.start.rejected"} = signal} ->
            if start_response_matches_request?(signal, request_signal_id) do
              {:ok, signal}
            else
              do_await_start_response(request_signal_id, timeout_ms, started_at)
            end

          {:signal, %Signal{}} ->
            do_await_start_response(request_signal_id, timeout_ms, started_at)
        after
          remaining ->
            {:error, :timeout}
        end
    end
  end

  # Require explicit correlation to avoid consuming unrelated start responses.
  defp start_response_matches_request?(%Signal{} = signal, request_signal_id) do
    case fetch(signal.data, "requested_signal_id") do
      ^request_signal_id -> true
      nil -> false
      _other -> false
    end
  end

  defp await_run_terminal_signal(run_id, timeout_ms) do
    started_at = now_ms()
    do_await_run_terminal_signal(run_id, timeout_ms, started_at)
  end

  defp do_await_run_terminal_signal(run_id, timeout_ms, started_at) do
    case remaining_timeout(timeout_ms, started_at) do
      :timeout ->
        {:error, :timeout}

      remaining ->
        receive do
          {:signal, %Signal{type: type} = signal}
          when type in ["workflow.run.completed", "workflow.run.failed", "workflow.run.cancelled"] ->
            if fetch(signal.data, "run_id") == run_id do
              {:ok, signal}
            else
              do_await_run_terminal_signal(run_id, timeout_ms, started_at)
            end

          {:signal, %Signal{}} ->
            do_await_run_terminal_signal(run_id, timeout_ms, started_at)
        after
          remaining ->
            {:error, :timeout}
        end
    end
  end

  defp terminal_status("workflow.run.completed"), do: "completed"
  defp terminal_status("workflow.run.failed"), do: "failed"
  defp terminal_status("workflow.run.cancelled"), do: "cancelled"
  defp terminal_status(_other), do: "unknown"

  defp parse_workflow_id([workflow_id | _rest]) when is_binary(workflow_id) do
    workflow_id
    |> String.trim()
    |> case do
      "" -> Mix.raise("A workflow_id positional argument is required")
      normalized -> normalized
    end
  end

  defp parse_workflow_id(_args), do: Mix.raise("Usage: mix workflow.run <workflow_id> [options]")

  defp parse_source(source) when is_binary(source) do
    source
    |> String.trim()
    |> case do
      "" -> @default_source
      normalized -> normalized
    end
  end

  defp parse_source(_source), do: @default_source

  defp parse_bus(nil), do: Broadcaster.default_bus()

  defp parse_bus(bus) when is_binary(bus) do
    bus
    |> String.trim()
    |> String.trim_leading(":")
    |> case do
      "" -> Broadcaster.default_bus()
      normalized -> to_existing_atom!(normalized)
    end
  end

  defp parse_bus(_bus), do: Broadcaster.default_bus()

  defp to_existing_atom!(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError ->
      Mix.raise(
        "--bus must reference an existing atom name (got: #{inspect(value)}). " <>
          "Start the bus first or use the default bus."
      )
  end

  defp subscribe_run_signal_patterns(bus) do
    Enum.reduce_while(@run_signal_patterns, {:ok, []}, fn pattern, {:ok, subscription_ids} ->
      case Bus.subscribe(bus, pattern, dispatch: {:pid, target: self()}) do
        {:ok, subscription_id} ->
          {:cont, {:ok, [subscription_id | subscription_ids]}}

        {:error, reason} ->
          unsubscribe_all(bus, subscription_ids)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, subscription_ids} -> {:ok, Enum.reverse(subscription_ids)}
      other -> other
    end
  end

  defp unsubscribe_all(bus, subscription_ids) do
    Enum.each(subscription_ids, fn subscription_id ->
      _ = Bus.unsubscribe(bus, subscription_id)
    end)

    :ok
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_value), do: @default_timeout_ms

  defp decode_inputs!(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = decoded} ->
        decoded

      {:ok, other} ->
        Mix.raise("--inputs must decode to a JSON object map, got: #{inspect(other)}")

      {:error, reason} ->
        Mix.raise("Invalid --inputs JSON: #{Exception.message(reason)}")
    end
  end

  defp decode_inputs!(_json), do: Mix.raise("--inputs must be a JSON string")

  defp normalize_optional_binary(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_binary(_value), do: nil

  defp normalize_backend(nil), do: nil

  defp normalize_backend(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "direct" -> "direct"
      "strategy" -> "strategy"
      "" -> nil
      other -> Mix.raise("--backend must be one of: direct, strategy (got: #{other})")
    end
  end

  defp normalize_backend(_value), do: Mix.raise("--backend must be a string value")

  defp serialize_signal(%Signal{} = signal) do
    %{
      "id" => signal.id,
      "type" => signal.type,
      "source" => signal.source,
      "data" => signal.data
    }
  end

  defp print_json(payload, pretty?) do
    encoded =
      if pretty? do
        Jason.encode!(payload, pretty: true)
      else
        Jason.encode!(payload)
      end

    Mix.shell().info(encoded)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp valid_binary?(value), do: is_binary(value) and value != ""

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_atom_key(map, key)
    end
  end

  defp fetch(_map, _key), do: nil

  defp fetch_atom_key(map, key) do
    Enum.find_value(map, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end

  defp remaining_timeout(timeout_ms, started_at) do
    elapsed = now_ms() - started_at
    remaining = timeout_ms - elapsed
    if remaining <= 0, do: :timeout, else: remaining
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
