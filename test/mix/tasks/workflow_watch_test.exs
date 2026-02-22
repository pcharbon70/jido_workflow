defmodule Mix.Tasks.Workflow.WatchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Mix.Tasks.Workflow.Watch

  setup do
    bus = unique_name("mix_task_watch_bus")
    start_supervised!({Bus, name: bus})

    on_exit(fn ->
      Mix.Task.reenable("workflow.watch")
    end)

    {:ok, bus: bus}
  end

  test "streams matching signal events until limit is reached", context do
    spawn(fn ->
      Enum.each(1..80, fn _ ->
        _ =
          publish(
            context.bus,
            "workflow.run.started",
            %{"workflow_id" => "watch_flow", "run_id" => "run_watch_1"}
          )

        _ =
          publish(
            context.bus,
            "workflow.run.completed",
            %{
              "workflow_id" => "watch_flow",
              "run_id" => "run_watch_1",
              "result" => %{"echo" => "ok"}
            }
          )

        Process.sleep(25)
      end)
    end)

    output =
      capture_io(fn ->
        Watch.run([
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus),
          "--pattern",
          "workflow.run.*",
          "--limit",
          "2",
          "--timeout",
          "3000"
        ])
      end)

    lines = decode_json_lines(output)
    assert [%{"event" => "watch.started"} | _rest] = lines

    signal_types =
      lines
      |> Enum.filter(&(&1["event"] == "signal"))
      |> Enum.map(&get_in(&1, ["signal", "type"]))

    assert Enum.sort(signal_types) ==
             Enum.sort(["workflow.run.started", "workflow.run.completed"])

    assert %{"event" => "watch.completed", "reason" => "limit", "count" => 2} = List.last(lines)
  end

  test "completes on timeout when no matching signals are received", context do
    output =
      capture_io(fn ->
        Watch.run([
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus),
          "--pattern",
          "workflow.step.*",
          "--timeout",
          "50"
        ])
      end)

    lines = decode_json_lines(output)
    assert [%{"event" => "watch.started"}, %{"event" => "watch.completed"}] = lines
    assert %{"reason" => "timeout", "count" => 0} = List.last(lines)
  end

  test "uses default workflow pattern when no --pattern is provided", context do
    spawn(fn ->
      Enum.each(1..80, fn _ ->
        _ =
          publish(
            context.bus,
            "workflow.run.failed",
            %{"workflow_id" => "default_pattern_flow", "reason" => "boom"}
          )

        Process.sleep(25)
      end)
    end)

    output =
      capture_io(fn ->
        Watch.run([
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus),
          "--limit",
          "1",
          "--timeout",
          "3000"
        ])
      end)

    lines = decode_json_lines(output)

    assert %{
             "patterns" => ["workflow.run.*", "workflow.step.*", "workflow.agent.state"]
           } = hd(lines)

    assert Enum.any?(lines, fn
             %{"event" => "signal", "signal" => %{"type" => "workflow.run.failed"}} -> true
             _other -> false
           end)

    assert %{"event" => "watch.completed", "reason" => "limit", "count" => 1} = List.last(lines)
  end

  test "raises on invalid limit value", context do
    assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
      capture_io(fn ->
        Watch.run([
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus),
          "--limit",
          "0",
          "--timeout",
          "100"
        ])
      end)
    end
  end

  defp publish(bus, type, data) do
    case Bus.publish(bus, [Signal.new!(type, data, source: "/test/workflow.watch")]) do
      {:ok, _published} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp decode_json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
