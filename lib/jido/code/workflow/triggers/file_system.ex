defmodule Jido.Code.Workflow.Triggers.FileSystem do
  @moduledoc """
  File-system trigger process.

  Watches configured directories for matching file events and executes the
  configured workflow with debounced trigger payloads.
  """

  use GenServer

  alias Elixir.FileSystem, as: FileWatcher
  alias Jido.Code.Workflow.Broadcaster
  alias Jido.Code.Workflow.Engine
  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry

  @default_debounce_ms 500
  @default_events MapSet.new(["created", "modified"])
  @default_process_registry Jido.Code.Workflow.TriggerProcessRegistry

  @type state :: %{
          id: String.t(),
          workflow_id: String.t(),
          root_dir: String.t(),
          patterns: [String.t()],
          compiled_patterns: [Regex.t()],
          events: MapSet.t(String.t()),
          debounce_ms: non_neg_integer(),
          pending_events: %{optional(String.t()) => MapSet.t(String.t())},
          debounce_timers: %{optional(String.t()) => reference()},
          watcher_pid: pid(),
          workflow_registry: GenServer.server(),
          bus: atom(),
          backend: Engine.backend() | nil
        }

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) when is_map(config) do
    process_registry = fetch(config, "process_registry") || default_process_registry()
    id = fetch(config, "id")

    GenServer.start_link(__MODULE__, config, name: via_tuple(id, process_registry))
  end

  @impl true
  def init(config) do
    id = fetch(config, "id")
    workflow_id = fetch(config, "workflow_id")
    patterns = normalize_patterns(fetch(config, "patterns"))
    root_dir = normalize_root_dir(fetch(config, "root_dir"))
    events = normalize_events(fetch(config, "events"))
    debounce_ms = normalize_debounce_ms(fetch(config, "debounce_ms"))

    workflow_registry =
      fetch(config, "workflow_registry") || fetch(config, "registry") || WorkflowRegistry

    bus = fetch(config, "bus") || Broadcaster.default_bus()
    backend = normalize_backend(fetch(config, "backend"))
    watch_dirs = resolve_watch_directories(patterns, root_dir)

    with :ok <- require_binary(id, :id),
         :ok <- require_binary(workflow_id, :workflow_id),
         :ok <- require_patterns(patterns),
         {:ok, compiled_patterns} <- compile_patterns(patterns),
         {:ok, watcher_pid} <- start_watcher(watch_dirs) do
      {:ok,
       %{
         id: id,
         workflow_id: workflow_id,
         root_dir: root_dir,
         patterns: patterns,
         compiled_patterns: compiled_patterns,
         events: events,
         debounce_ms: debounce_ms,
         pending_events: %{},
         debounce_timers: %{},
         watcher_pid: watcher_pid,
         workflow_registry: workflow_registry,
         bus: bus,
         backend: backend
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, raw_events}}, state) do
    normalized_path = normalize_path(path)

    if should_trigger?(normalized_path, raw_events, state) do
      {:noreply, schedule_debounce(state, normalized_path, raw_events)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:trigger_debounced, path}, state) do
    {events, pending_events} = Map.pop(state.pending_events, path)
    {_timer, debounce_timers} = Map.pop(state.debounce_timers, path)

    if events do
      payload =
        %{
          "trigger_type" => "file_system",
          "trigger_id" => state.id,
          "triggered_at" => timestamp(),
          "file_path" => path,
          "events" => events |> MapSet.to_list() |> Enum.sort()
        }

      _ = execute_workflow(state, payload)
    end

    {:noreply, %{state | pending_events: pending_events, debounce_timers: debounce_timers}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.debounce_timers, fn {_path, timer_ref} ->
      _ = Process.cancel_timer(timer_ref)
    end)

    :ok
  end

  defp execute_workflow(state, payload) do
    opts =
      [registry: state.workflow_registry, bus: state.bus]
      |> maybe_put_backend(state.backend)

    Engine.execute(state.workflow_id, payload, opts)
  end

  defp schedule_debounce(state, path, raw_events) do
    events = raw_events |> normalize_event_list() |> MapSet.new()

    pending_events =
      Map.update(state.pending_events, path, events, fn existing ->
        MapSet.union(existing, events)
      end)

    debounce_timers =
      case Map.pop(state.debounce_timers, path) do
        {nil, timers} ->
          timers

        {timer_ref, timers} ->
          _ = Process.cancel_timer(timer_ref)
          timers
      end

    timer_ref = Process.send_after(self(), {:trigger_debounced, path}, state.debounce_ms)
    debounce_timers = Map.put(debounce_timers, path, timer_ref)

    %{state | pending_events: pending_events, debounce_timers: debounce_timers}
  end

  defp should_trigger?(path, raw_events, state) do
    normalized_events = normalize_event_list(raw_events)

    path_matches?(path, state.compiled_patterns, state.root_dir) and
      events_match?(normalized_events, state.events) and
      not_git_internal?(path)
  end

  defp path_matches?(path, compiled_patterns, root_dir) do
    relative_path = Path.relative_to(path, root_dir) |> normalize_path()

    Enum.any?(compiled_patterns, fn regex ->
      Regex.match?(regex, path) or Regex.match?(regex, relative_path)
    end)
  end

  defp events_match?(normalized_events, configured_events) do
    Enum.any?(normalized_events, &MapSet.member?(configured_events, &1))
  end

  defp not_git_internal?(path) do
    not String.contains?(path, "/.git/") and not String.ends_with?(path, "/.git")
  end

  defp compile_patterns(patterns) do
    patterns
    |> Enum.reduce_while({:ok, []}, fn pattern, {:ok, acc} ->
      case compile_pattern(pattern) do
        {:ok, regex} -> {:cont, {:ok, [regex | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, regexes} -> {:ok, Enum.reverse(regexes)}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp compile_pattern(pattern) do
    normalized = normalize_path(pattern)
    wildcard_placeholder = "__DOUBLE_WILDCARD__"
    dir_placeholder = "__DOUBLE_DIRECTORY_WILDCARD__"

    escaped =
      normalized
      |> Regex.escape()
      |> String.replace("\\*\\*/", dir_placeholder)
      |> String.replace("\\*\\*", wildcard_placeholder)
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")
      |> String.replace(dir_placeholder, "(?:.*/)?")
      |> String.replace(wildcard_placeholder, ".*")

    Regex.compile("^" <> escaped <> "$")
  end

  defp resolve_watch_directories(patterns, root_dir) do
    patterns
    |> Enum.map(&watch_directory_for_pattern(&1, root_dir))
    |> Enum.uniq()
    |> case do
      [] -> [root_dir]
      dirs -> dirs
    end
  end

  defp watch_directory_for_pattern(pattern, root_dir) do
    normalized = normalize_path(pattern)
    wildcard_index = wildcard_index(normalized)

    base =
      cond do
        wildcard_index == nil ->
          expanded = Path.expand(normalized, root_dir)
          if File.dir?(expanded), do: expanded, else: Path.dirname(expanded)

        wildcard_index == 0 ->
          root_dir

        true ->
          normalized
          |> String.slice(0, wildcard_index)
          |> String.trim_trailing("/")
          |> case do
            "" -> root_dir
            prefix -> Path.expand(prefix, root_dir)
          end
      end

    if File.dir?(base), do: base, else: root_dir
  end

  defp wildcard_index(path) do
    [binary_index(path, "*"), binary_index(path, "?")]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp binary_index(path, pattern) do
    case :binary.match(path, pattern) do
      {index, _length} -> index
      :nomatch -> nil
    end
  end

  defp start_watcher(watch_dirs) do
    with {:ok, watcher_pid} <- FileWatcher.start_link(dirs: watch_dirs),
         :ok <- FileWatcher.subscribe(watcher_pid) do
      {:ok, watcher_pid}
    else
      {:error, reason} -> {:error, {:watcher_start_failed, reason}}
      other -> {:error, {:watcher_start_failed, other}}
    end
  end

  defp maybe_put_backend(opts, nil), do: opts
  defp maybe_put_backend(opts, backend), do: Keyword.put(opts, :backend, backend)

  defp normalize_backend(value) when value in [:direct, :strategy], do: value
  defp normalize_backend(_value), do: nil

  defp normalize_patterns(nil), do: []

  defp normalize_patterns(patterns) when is_list(patterns) do
    patterns
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_patterns(pattern) when is_binary(pattern), do: [String.trim(pattern)]
  defp normalize_patterns(_other), do: []

  defp normalize_root_dir(path) when is_binary(path) and path != "" do
    Path.expand(path)
  end

  defp normalize_root_dir(_other), do: File.cwd!()

  defp normalize_events(nil), do: @default_events

  defp normalize_events(events) when is_list(events) do
    normalized =
      events
      |> Enum.map(&normalize_event/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    if MapSet.size(normalized) == 0, do: @default_events, else: normalized
  end

  defp normalize_events(event), do: normalize_events([event])

  defp normalize_event_list(events) when is_list(events) do
    events
    |> Enum.map(&normalize_event/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_event_list(event), do: normalize_event_list([event])

  defp normalize_event(event) when is_atom(event), do: normalize_event(Atom.to_string(event))

  defp normalize_event(event) when is_binary(event) do
    case String.downcase(event) do
      "created" -> "created"
      "modified" -> "modified"
      "deleted" -> "deleted"
      "moved" -> "moved"
      "renamed" -> "moved"
      "closed" -> "modified"
      "updated" -> "modified"
      _ -> nil
    end
  end

  defp normalize_event(_other), do: nil

  defp normalize_debounce_ms(value) when is_integer(value) and value >= 0, do: value
  defp normalize_debounce_ms(_value), do: @default_debounce_ms

  defp require_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_binary(_value, field), do: {:error, {:invalid_config, field}}

  defp require_patterns([]), do: {:error, {:invalid_config, :patterns}}
  defp require_patterns(_patterns), do: :ok

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp via_tuple(id, process_registry) do
    {:via, Elixir.Registry, {process_registry, id}}
  end

  defp default_process_registry do
    Application.get_env(:jido_workflow, :trigger_process_registry, @default_process_registry)
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        fetch_atom_key(map, key)
    end
  end

  defp fetch_atom_key(map, key) do
    Enum.find_value(map, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim()
  end

  defp normalize_path(other), do: to_string(other)
end
