defmodule JidoWorkflow.Workflow.Triggers.GitHook do
  @moduledoc """
  Git-hook trigger process.

  Watches repository `.git` metadata and executes workflows on git events.
  """

  use GenServer

  alias Elixir.FileSystem, as: FileWatcher
  alias JidoWorkflow.Workflow.Broadcaster
  alias JidoWorkflow.Workflow.Engine
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry

  @default_events MapSet.new(["commit", "push"])
  @default_process_registry JidoWorkflow.Workflow.TriggerProcessRegistry

  @type state :: %{
          id: String.t(),
          workflow_id: String.t(),
          events: MapSet.t(String.t()),
          repo_path: String.t(),
          git_dir: String.t(),
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
    repo_path = normalize_repo_path(fetch(config, "repo_path"))
    git_dir = Path.join(repo_path, ".git")
    events = normalize_events(fetch(config, "events"))

    workflow_registry =
      fetch(config, "workflow_registry") || fetch(config, "registry") || WorkflowRegistry

    bus = fetch(config, "bus") || Broadcaster.default_bus()
    backend = normalize_backend(fetch(config, "backend"))

    with :ok <- require_binary(id, :id),
         :ok <- require_binary(workflow_id, :workflow_id),
         :ok <- require_git_dir(git_dir),
         {:ok, watcher_pid} <- start_watcher([git_dir]) do
      {:ok,
       %{
         id: id,
         workflow_id: workflow_id,
         events: events,
         repo_path: repo_path,
         git_dir: git_dir,
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
    case detect_git_event(path, raw_events, state.git_dir) do
      git_event when is_binary(git_event) ->
        if MapSet.member?(state.events, git_event) do
          payload = git_payload(state, git_event)
          _ = execute_workflow(state, payload)
        end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp execute_workflow(state, payload) do
    opts =
      [registry: state.workflow_registry, bus: state.bus]
      |> maybe_put_backend(state.backend)

    Engine.execute(state.workflow_id, payload, opts)
  end

  defp git_payload(state, git_event) do
    %{
      "trigger_type" => "git_hook",
      "trigger_id" => state.id,
      "triggered_at" => timestamp(),
      "git_event" => git_event,
      "branch" => current_branch(state.repo_path),
      "commit" => head_commit(state.repo_path)
    }
  end

  defp detect_git_event(path, _raw_events, git_dir) do
    normalized_path = normalize_path(path)
    normalized_git_dir = normalize_path(git_dir)

    cond do
      String.contains?(normalized_path, normalized_git_dir <> "/refs/heads/") -> "push"
      String.ends_with?(normalized_path, normalized_git_dir <> "/COMMIT_EDITMSG") -> "commit"
      String.ends_with?(normalized_path, normalized_git_dir <> "/MERGE_HEAD") -> "merge"
      true -> nil
    end
  end

  defp current_branch(repo_path) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {branch, 0} -> String.trim(branch)
      _ -> "unknown"
    end
  end

  defp head_commit(repo_path) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
      {commit, 0} -> String.trim(commit)
      _ -> "unknown"
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

  defp normalize_event(event) when is_atom(event), do: normalize_event(Atom.to_string(event))

  defp normalize_event(event) when is_binary(event) do
    case String.downcase(event) do
      "commit" -> "commit"
      "push" -> "push"
      "merge" -> "merge"
      _ -> nil
    end
  end

  defp normalize_event(_other), do: nil

  defp normalize_repo_path(path) when is_binary(path) and path != "", do: Path.expand(path)
  defp normalize_repo_path(_other), do: File.cwd!()

  defp require_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_binary(_value, field), do: {:error, {:invalid_config, field}}

  defp require_git_dir(git_dir) do
    if File.dir?(git_dir) do
      :ok
    else
      {:error, {:invalid_config, :repo_path}}
    end
  end

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
