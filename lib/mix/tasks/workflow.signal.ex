defmodule Mix.Tasks.Workflow.Signal do
  @shortdoc "Publish a workflow signal on the Jido signal bus"

  @moduledoc """
  Publish workflow signals from the terminal.

  This task is primarily intended for `workflow.*.requested` command signals.
  By default it waits for the corresponding `*.accepted` / `*.rejected`
  response and prints a JSON payload describing the request and response.

  ## Examples

      mix workflow.signal workflow.run.start.requested \\
        --data '{"workflow_id":"my_flow","inputs":{"value":"hello"}}'

      mix workflow.signal workflow.registry.refresh.requested --data '{}' --timeout 10000

      mix workflow.signal workflow.run.start.requested \\
        --data '{"workflow_id":"my_flow"}' --no-wait
  """

  use Mix.Task

  alias Jido.Code.Workflow.Broadcaster
  alias Jido.Signal
  alias Jido.Signal.Bus

  @switches [
    data: :string,
    source: :string,
    bus: :string,
    timeout: :integer,
    wait: :boolean,
    start_app: :boolean,
    pretty: :boolean
  ]
  @aliases [d: :data, s: :source, b: :bus, t: :timeout]

  @default_source "/mix/workflow.signal"
  @default_timeout_ms 5_000

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

    signal_type = parse_signal_type(positional)
    wait? = Keyword.get(opts, :wait, true)
    start_app? = Keyword.get(opts, :start_app, true)
    pretty? = Keyword.get(opts, :pretty, true)
    timeout_ms = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout_ms))
    source = parse_source(Keyword.get(opts, :source, @default_source))
    bus = parse_bus(Keyword.get(opts, :bus, nil))
    data = decode_data!(Keyword.get(opts, :data, "{}"))

    if start_app? do
      Mix.Task.run("app.start")
    end

    if wait? and not String.ends_with?(signal_type, ".requested") do
      Mix.raise("--wait requires a signal type ending in .requested")
    end

    request_signal = Signal.new!(signal_type, data, source: source)

    case publish_and_collect(bus, request_signal, wait?, timeout_ms) do
      {:ok, output} ->
        print_json(output, pretty?)

      {:error, {:rejected, %Signal{} = response_signal}} ->
        print_json(
          %{
            "status" => "rejected",
            "request" => serialize_signal(request_signal),
            "response" => serialize_signal(response_signal)
          },
          pretty?
        )

        Mix.raise("Signal rejected: #{response_signal.type}")

      {:error, :timeout} ->
        print_json(
          %{
            "status" => "timeout",
            "request" => serialize_signal(request_signal),
            "timeout_ms" => timeout_ms
          },
          pretty?
        )

        Mix.raise("Timed out waiting for response signal")

      {:error, reason} ->
        Mix.raise("Failed to publish signal: #{inspect(reason)}")
    end
  end

  defp parse_signal_type([signal_type | _rest]) when is_binary(signal_type) do
    signal_type
    |> String.trim()
    |> case do
      "" -> Mix.raise("A signal type is required")
      normalized -> normalized
    end
  end

  defp parse_signal_type(_args),
    do: Mix.raise("Usage: mix workflow.signal <signal_type> [options]")

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
      "" ->
        Broadcaster.default_bus()

      normalized ->
        to_existing_atom!(normalized)
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

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_value), do: @default_timeout_ms

  defp decode_data!(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = decoded} ->
        decoded

      {:ok, other} ->
        Mix.raise("--data must decode to a JSON object map, got: #{inspect(other)}")

      {:error, reason} ->
        Mix.raise("Invalid --data JSON: #{Exception.message(reason)}")
    end
  end

  defp decode_data!(_json), do: Mix.raise("--data must be a JSON string")

  defp publish_and_collect(bus, %Signal{} = request_signal, false, _timeout_ms) do
    case Bus.publish(bus, [request_signal]) do
      {:ok, _published} ->
        {:ok,
         %{
           "status" => "published",
           "request" => serialize_signal(request_signal)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_and_collect(bus, %Signal{} = request_signal, true, timeout_ms) do
    %{accepted: accepted, rejected: rejected, pattern: pattern} =
      response_contract(request_signal.type)

    with {:ok, subscription_id} <- Bus.subscribe(bus, pattern, dispatch: {:pid, target: self()}) do
      try do
        with {:ok, _published} <- Bus.publish(bus, [request_signal]),
             {:ok, response_signal} <-
               await_response(accepted, rejected, request_signal, timeout_ms) do
          {:ok,
           %{
             "status" => "accepted",
             "request" => serialize_signal(request_signal),
             "response" => serialize_signal(response_signal)
           }}
        end
      after
        _ = Bus.unsubscribe(bus, subscription_id)
      end
    end
  end

  defp response_contract(signal_type) when is_binary(signal_type) do
    prefix = String.replace_suffix(signal_type, ".requested", "")

    %{
      accepted: "#{prefix}.accepted",
      rejected: "#{prefix}.rejected",
      pattern: "#{prefix}.*"
    }
  end

  defp await_response(accepted, rejected, request_signal, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)
    do_await_response(accepted, rejected, request_signal, timeout_ms, started_at)
  end

  defp do_await_response(accepted, rejected, request_signal, timeout_ms, started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = timeout_ms - elapsed

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:signal, %Signal{type: ^accepted} = signal} ->
          if response_matches_request?(signal, request_signal) do
            {:ok, signal}
          else
            do_await_response(accepted, rejected, request_signal, timeout_ms, started_at)
          end

        {:signal, %Signal{type: ^rejected} = signal} ->
          if response_matches_request?(signal, request_signal) do
            {:error, {:rejected, signal}}
          else
            do_await_response(accepted, rejected, request_signal, timeout_ms, started_at)
          end

        {:signal, %Signal{}} ->
          do_await_response(accepted, rejected, request_signal, timeout_ms, started_at)
      after
        remaining ->
          {:error, :timeout}
      end
    end
  end

  # Require explicit correlation to avoid consuming unrelated command responses.
  defp response_matches_request?(%Signal{} = response, %Signal{} = request) do
    fetch(response.data, "requested_signal_id") == request.id
  end

  defp fetch(data, key) when is_map(data) do
    Map.get(data, key) || fetch_atom_key(data, key)
  end

  defp fetch(_data, _key), do: nil

  defp fetch_atom_key(map, key) do
    Enum.find_value(map, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end

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
end
