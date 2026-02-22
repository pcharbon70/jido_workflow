defmodule Jido.Code.Workflow.Registry.Entry do
  @moduledoc """
  Cached workflow registry entry.
  """

  @enforce_keys [:id, :path, :hash, :enabled]
  defstruct [
    :id,
    :path,
    :hash,
    :mtime,
    :enabled,
    :definition,
    :compiled,
    :errors,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          hash: String.t(),
          mtime: DateTime.t() | nil,
          enabled: boolean(),
          definition: Jido.Code.Workflow.Definition.t() | nil,
          compiled: term() | nil,
          errors: [term()],
          updated_at: DateTime.t()
        }
end

defmodule Jido.Code.Workflow.Registry do
  @moduledoc """
  Workflow discovery and cache registry.

  Responsibilities:
  - Discover `*.md` workflow files from a directory
  - Parse + validate them via `Workflow.Loader`
  - Cache compile results and avoid recompiling unchanged files
  - Support manual refresh and per-workflow reload
  """

  use GenServer

  alias Jido.Code.Workflow.Compiler
  alias Jido.Code.Workflow.Loader
  alias Jido.Code.Workflow.Registry.Entry
  alias Jido.Code.Workflow.ValidationError

  @type compile_fun :: (Jido.Code.Workflow.Definition.t() -> {:ok, term()} | {:error, term()})

  @doc """
  Starts the registry.

  Options:
  - `:workflow_dir` - directory containing `*.md` workflow files
  - `:compile_fun` - compiler function for validated definitions
  - `:name` - process registration name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Refreshes registry state by scanning the workflow directory.
  """
  @spec refresh(GenServer.server()) :: {:ok, map()}
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  @doc """
  Reloads a specific workflow by id, bypassing hash cache.
  """
  @spec reload(String.t(), GenServer.server()) :: {:ok, map()} | {:error, :not_found}
  def reload(id, server \\ __MODULE__) when is_binary(id),
    do: GenServer.call(server, {:reload, id})

  @doc """
  Returns metadata for known workflows.
  """
  @spec list(GenServer.server(), keyword()) :: [map()]
  def list(server \\ __MODULE__, opts \\ []), do: GenServer.call(server, {:list, opts})

  @doc """
  Returns compiled workflow payload for an enabled workflow.
  """
  @spec get_compiled(String.t(), GenServer.server()) ::
          {:ok, term()}
          | {:error, :not_found | :disabled | {:not_compiled, [term()]}}
  def get_compiled(id, server \\ __MODULE__) when is_binary(id),
    do: GenServer.call(server, {:get_compiled, id})

  @doc """
  Returns validated workflow definition for a workflow id.
  """
  @spec get_definition(String.t(), GenServer.server()) ::
          {:ok, Jido.Code.Workflow.Definition.t()} | {:error, :not_found | :invalid}
  def get_definition(id, server \\ __MODULE__) when is_binary(id),
    do: GenServer.call(server, {:get_definition, id})

  @impl true
  def init(opts) do
    workflow_dir =
      opts
      |> Keyword.get(:workflow_dir, ".jido_code/workflows")
      |> Path.expand()

    compile_fun = Keyword.get(opts, :compile_fun, &default_compile/1)

    state = %{
      workflow_dir: workflow_dir,
      compile_fun: compile_fun,
      entries: %{},
      by_path: %{}
    }

    {:ok, state, {:continue, :initial_refresh}}
  end

  @impl true
  def handle_continue(:initial_refresh, state) do
    {next_state, _summary} = do_refresh(state, force_paths: MapSet.new())
    {:noreply, next_state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {next_state, summary} = do_refresh(state, force_paths: MapSet.new())
    {:reply, {:ok, summary}, next_state}
  end

  def handle_call({:reload, id}, _from, state) do
    case Map.get(state.entries, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Entry{path: path} ->
        force = MapSet.new([path])
        {next_state, summary} = do_refresh(state, force_paths: force)
        {:reply, {:ok, summary}, next_state}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    include_disabled = Keyword.get(opts, :include_disabled, true)
    include_invalid = Keyword.get(opts, :include_invalid, true)

    items =
      state.entries
      |> Map.values()
      |> Enum.filter(fn entry ->
        valid_enabled_filter?(entry, include_disabled, include_invalid)
      end)
      |> Enum.map(&entry_metadata/1)
      |> Enum.sort_by(& &1.id)

    {:reply, items, state}
  end

  def handle_call({:get_compiled, id}, _from, state) do
    reply =
      case Map.get(state.entries, id) do
        nil ->
          {:error, :not_found}

        %Entry{enabled: false} ->
          {:error, :disabled}

        %Entry{compiled: nil, errors: errors} ->
          {:error, {:not_compiled, errors}}

        %Entry{compiled: compiled} ->
          {:ok, compiled}
      end

    {:reply, reply, state}
  end

  def handle_call({:get_definition, id}, _from, state) do
    reply =
      case Map.get(state.entries, id) do
        %Entry{definition: nil} -> {:error, :invalid}
        %Entry{definition: definition} -> {:ok, definition}
        nil -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  defp do_refresh(state, opts) do
    force_paths = Keyword.get(opts, :force_paths, MapSet.new())
    paths = workflow_paths(state.workflow_dir)
    seen_paths = MapSet.new(paths)

    refresh_acc =
      paths
      |> Enum.reduce(new_refresh_acc(state), fn path, acc ->
        refresh_path(path, state.compile_fun, force_paths, acc)
      end)

    removed_paths =
      state.by_path
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(seen_paths, &1))

    {entries, by_path, removed_count} =
      Enum.reduce(removed_paths, {refresh_acc.entries, refresh_acc.by_path, 0}, fn removed_path,
                                                                                   {entries_acc,
                                                                                    by_path_acc,
                                                                                    count} ->
        case Map.pop(by_path_acc, removed_path) do
          {nil, by_path_acc} ->
            {entries_acc, by_path_acc, count}

          {id, by_path_acc} ->
            {Map.delete(entries_acc, id), by_path_acc, count + 1}
        end
      end)

    summary = %{
      workflow_dir: state.workflow_dir,
      total: map_size(entries),
      loaded: refresh_acc.loaded,
      changed: refresh_acc.changed,
      skipped: refresh_acc.skipped,
      removed: removed_count,
      errors: refresh_acc.errors
    }

    {%{state | entries: entries, by_path: by_path}, summary}
  end

  defp new_refresh_acc(state) do
    %{
      entries: state.entries,
      by_path: state.by_path,
      loaded: 0,
      changed: 0,
      skipped: 0,
      errors: []
    }
  end

  defp refresh_path(path, compile_fun, force_paths, acc) do
    case current_entry_for_path(acc.entries, acc.by_path, path) do
      {:ok, %Entry{} = current_entry} ->
        refresh_existing_path(path, current_entry, compile_fun, force_paths, acc)

      :error ->
        upsert_built_entry(path, nil, build_entry(path, compile_fun), acc, false)
    end
  end

  defp refresh_existing_path(path, current_entry, compile_fun, force_paths, acc) do
    unchanged? = current_entry.hash == file_hash(path) and not MapSet.member?(force_paths, path)

    if unchanged? do
      %{acc | skipped: acc.skipped + 1}
    else
      upsert_built_entry(path, current_entry.id, build_entry(path, compile_fun), acc, true)
    end
  end

  defp upsert_built_entry(path, old_id, {:ok, entry}, acc, changed?) do
    entries =
      acc.entries
      |> maybe_delete_entry(old_id)
      |> Map.put(entry.id, entry)

    %{
      acc
      | entries: entries,
        by_path: Map.put(acc.by_path, path, entry.id),
        loaded: acc.loaded + 1,
        changed: bump_changed(acc.changed, changed?)
    }
  end

  defp upsert_built_entry(
         path,
         old_id,
         {:error, entry_id, entry_errors, fallback_entry},
         acc,
         changed?
       ) do
    entries =
      acc.entries
      |> maybe_delete_entry(old_id)
      |> Map.put(entry_id, fallback_entry)

    %{
      acc
      | entries: entries,
        by_path: Map.put(acc.by_path, path, entry_id),
        loaded: acc.loaded + 1,
        changed: bump_changed(acc.changed, changed?),
        errors: acc.errors ++ entry_errors
    }
  end

  defp maybe_delete_entry(entries, nil), do: entries
  defp maybe_delete_entry(entries, id), do: Map.delete(entries, id)
  defp bump_changed(count, true), do: count + 1
  defp bump_changed(count, false), do: count

  defp build_entry(path, compile_fun) do
    with {:ok, definition} <- Loader.load_file(path),
         {:ok, compiled} <- compile_fun.(definition) do
      entry = %Entry{
        id: definition.name,
        path: path,
        hash: file_hash(path),
        mtime: file_mtime(path),
        enabled: definition.enabled,
        definition: definition,
        compiled: compiled,
        errors: [],
        updated_at: DateTime.utc_now()
      }

      {:ok, entry}
    else
      {:error, reason} when is_list(reason) ->
        errors = reason
        entry_id = fallback_id(path)
        {:error, entry_id, errors, fallback_invalid_entry(path, entry_id, errors)}

      {:error, reason} ->
        errors = [
          %ValidationError{path: ["compile"], code: :compile_error, message: inspect(reason)}
        ]

        entry_id = fallback_id(path)
        {:error, entry_id, errors, fallback_invalid_entry(path, entry_id, errors)}
    end
  end

  defp fallback_invalid_entry(path, id, errors) do
    %Entry{
      id: id,
      path: path,
      hash: file_hash(path),
      mtime: file_mtime(path),
      enabled: false,
      definition: nil,
      compiled: nil,
      errors: errors,
      updated_at: DateTime.utc_now()
    }
  end

  defp current_entry_for_path(entries, by_path, path) do
    with id when not is_nil(id) <- Map.get(by_path, path),
         %Entry{} = entry <- Map.get(entries, id) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  defp entry_metadata(entry) do
    %{
      id: entry.id,
      path: entry.path,
      enabled: entry.enabled,
      valid?: entry.definition != nil and entry.errors == [],
      hash: entry.hash,
      updated_at: entry.updated_at,
      error_count: length(entry.errors || [])
    }
  end

  defp valid_enabled_filter?(entry, include_disabled, include_invalid) do
    enabled_ok = include_disabled || entry.enabled
    valid_ok = include_invalid || (entry.definition != nil and entry.errors == [])
    enabled_ok and valid_ok
  end

  defp workflow_paths(dir) do
    if File.dir?(dir) do
      Path.join(dir, "*.md") |> Path.wildcard() |> Enum.sort()
    else
      []
    end
  end

  defp file_hash(path) do
    case File.read(path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:error, _} -> ""
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> DateTime.from_unix!(stat.mtime)
      {:error, _} -> nil
    end
  end

  defp fallback_id(path) do
    path |> Path.basename(".md") |> String.replace(~r/[^a-zA-Z0-9_]+/, "_")
  end

  defp default_compile(definition), do: Compiler.compile(definition)
end
