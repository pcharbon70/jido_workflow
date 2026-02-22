defmodule Jido.Code.Workflow.TriggerManager do
  @moduledoc """
  Syncs trigger processes from workflow definitions and optional global trigger
  configuration.
  """

  alias Jido.Code.Workflow.Broadcaster
  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry
  alias Jido.Code.Workflow.TriggerConfig
  alias Jido.Code.Workflow.TriggerSupervisor

  @default_process_registry Jido.Code.Workflow.TriggerProcessRegistry

  @type sync_summary :: %{
          configured: non_neg_integer(),
          desired: non_neg_integer(),
          limited: non_neg_integer(),
          max_concurrent_triggers: pos_integer() | nil,
          started: non_neg_integer(),
          skipped: non_neg_integer(),
          stopped: non_neg_integer(),
          unsupported: non_neg_integer(),
          errors: [term()]
        }

  @spec sync_from_registry(keyword()) :: {:ok, sync_summary()} | {:error, term()}
  def sync_from_registry(opts \\ []) do
    workflow_registry = Keyword.get(opts, :workflow_registry, default_workflow_registry())
    trigger_supervisor = Keyword.get(opts, :trigger_supervisor, TriggerSupervisor)
    process_registry = process_registry(opts)

    with {:ok, %{configs: desired_configs, global_settings: global_settings}} <-
           desired_trigger_configs(workflow_registry, opts) do
      {active_configs, limited, max_concurrent_triggers} =
        apply_max_concurrent_limit(desired_configs, global_settings)

      desired_ids = MapSet.new(active_configs, & &1.id)

      existing_ids =
        MapSet.new(TriggerSupervisor.list_trigger_ids(process_registry: process_registry))

      stopped =
        existing_ids
        |> MapSet.difference(desired_ids)
        |> MapSet.to_list()
        |> stop_triggers(trigger_supervisor, process_registry)

      start_stats =
        Enum.reduce(
          active_configs,
          %{started: 0, skipped: 0, unsupported: 0, errors: []},
          fn config, acc ->
            maybe_start_trigger(
              config,
              existing_ids,
              trigger_supervisor,
              process_registry,
              acc
            )
          end
        )

      {:ok,
       %{
         configured: length(desired_configs),
         desired: length(active_configs),
         limited: limited,
         max_concurrent_triggers: max_concurrent_triggers,
         started: start_stats.started,
         skipped: start_stats.skipped,
         stopped: stopped,
         unsupported: start_stats.unsupported,
         errors: Enum.reverse(start_stats.errors)
       }}
    end
  end

  defp maybe_start_trigger(config, existing_ids, trigger_supervisor, process_registry, acc) do
    if MapSet.member?(existing_ids, config.id) do
      %{acc | skipped: acc.skipped + 1}
    else
      config
      |> TriggerSupervisor.start_trigger(
        supervisor: trigger_supervisor,
        process_registry: process_registry
      )
      |> apply_start_result(acc)
    end
  end

  defp apply_start_result({:ok, _pid}, acc), do: %{acc | started: acc.started + 1}

  defp apply_start_result({:error, {:unsupported_trigger_type, _type} = reason}, acc) do
    %{acc | unsupported: acc.unsupported + 1, errors: [reason | acc.errors]}
  end

  defp apply_start_result({:error, reason}, acc) do
    %{acc | errors: [reason | acc.errors]}
  end

  defp desired_trigger_configs(workflow_registry, opts) do
    bus = Keyword.get(opts, :bus, Broadcaster.default_bus())
    backend = Keyword.get(opts, :backend)
    process_registry = process_registry(opts)

    triggers_config_path =
      Keyword.get(opts, :triggers_config_path, default_triggers_config_path())

    try do
      workflows =
        WorkflowRegistry.list(workflow_registry, include_disabled: false, include_invalid: false)

      {workflow_configs, workflow_errors} =
        Enum.reduce(workflows, {[], []}, fn workflow, {acc, err_acc} ->
          workflow_id = workflow.id

          case WorkflowRegistry.get_definition(workflow_id, workflow_registry) do
            {:ok, definition} ->
              trigger_configs =
                definition.triggers
                |> List.wrap()
                |> Enum.with_index()
                |> Enum.map(fn {trigger, index} ->
                  build_trigger_config(
                    workflow_id,
                    trigger,
                    index,
                    workflow_registry,
                    bus,
                    backend,
                    process_registry
                  )
                end)

              {acc ++ trigger_configs, err_acc}

            {:error, reason} ->
              {acc, [{workflow_id, reason} | err_acc]}
          end
        end)

      if workflow_errors == [] do
        case load_global_trigger_configs(
               triggers_config_path,
               workflow_registry,
               bus,
               backend,
               process_registry
             ) do
          {:ok, %{configs: global_configs, global_settings: global_settings}} ->
            with {:ok, merged_configs} <- merge_trigger_configs(workflow_configs, global_configs) do
              {:ok,
               %{
                 configs: apply_default_debounce_ms(merged_configs, global_settings),
                 global_settings: global_settings
               }}
            end

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, Enum.reverse(workflow_errors)}
      end
    rescue
      error ->
        {:error, {:registry_access_failed, Exception.message(error)}}
    end
  end

  defp load_global_trigger_configs(
         triggers_config_path,
         workflow_registry,
         bus,
         backend,
         process_registry
       ) do
    case TriggerConfig.load_document(triggers_config_path) do
      {:ok, %{triggers: entries, global_settings: global_settings}} ->
        configs =
          entries
          |> Enum.reject(&(fetch(&1, "enabled") == false))
          |> Enum.map(fn config ->
            build_global_trigger_config(
              config,
              workflow_registry,
              bus,
              backend,
              process_registry
            )
          end)

        {:ok, %{configs: configs, global_settings: normalize_global_settings(global_settings)}}

      {:error, errors} when is_list(errors) ->
        {:error, {:invalid_trigger_config, errors}}
    end
  end

  defp build_global_trigger_config(config, workflow_registry, bus, backend, process_registry) do
    config
    |> Map.delete(:enabled)
    |> Map.delete("enabled")
    |> Map.put(:id, fetch(config, "id"))
    |> Map.put(:workflow_id, fetch(config, "workflow_id"))
    |> Map.put(:type, fetch(config, "type"))
    |> Map.put(:workflow_registry, workflow_registry)
    |> Map.put(:bus, bus)
    |> Map.put(:backend, backend)
    |> Map.put(:process_registry, process_registry)
  end

  defp merge_trigger_configs(workflow_configs, global_configs) do
    merged = workflow_configs ++ global_configs

    case duplicate_trigger_ids(merged) do
      [] ->
        {:ok, merged}

      duplicates ->
        {:error, {:duplicate_trigger_ids, duplicates}}
    end
  end

  defp apply_default_debounce_ms(configs, global_settings)
       when is_list(configs) and is_map(global_settings) do
    case fetch(global_settings, "default_debounce_ms") do
      debounce_ms when is_integer(debounce_ms) and debounce_ms >= 0 ->
        Enum.map(configs, &apply_file_system_default_debounce(&1, debounce_ms))

      _other ->
        configs
    end
  end

  defp apply_file_system_default_debounce(config, debounce_ms) when is_map(config) do
    case {fetch(config, "type"), fetch(config, "debounce_ms")} do
      {"file_system", nil} ->
        Map.put(config, :debounce_ms, debounce_ms)

      _other ->
        config
    end
  end

  defp apply_file_system_default_debounce(config, _debounce_ms), do: config

  defp apply_max_concurrent_limit(configs, global_settings) do
    total = length(configs)

    case max_concurrent_triggers(global_settings) do
      limit when is_integer(limit) ->
        {Enum.take(configs, limit), max(total - limit, 0), limit}

      nil ->
        {configs, 0, nil}
    end
  end

  defp max_concurrent_triggers(global_settings) when is_map(global_settings) do
    case Map.fetch(global_settings, :max_concurrent_triggers) do
      {:ok, limit} when is_integer(limit) and limit > 0 -> limit
      _other -> nil
    end
  end

  defp normalize_global_settings(settings) when is_map(settings) do
    %{}
    |> maybe_put_setting(
      :default_debounce_ms,
      normalize_non_neg_integer(fetch(settings, "default_debounce_ms"))
    )
    |> maybe_put_setting(
      :max_concurrent_triggers,
      normalize_positive_integer(fetch(settings, "max_concurrent_triggers"))
    )
  end

  defp maybe_put_setting(settings, _key, nil), do: settings
  defp maybe_put_setting(settings, key, value), do: Map.put(settings, key, value)

  defp normalize_non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_integer(_value), do: nil

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value), do: nil

  defp duplicate_trigger_ids(configs) do
    configs
    |> Enum.reduce(%{}, fn config, acc ->
      id = to_string(fetch(config, "id"))
      Map.update(acc, id, 1, &(&1 + 1))
    end)
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp stop_triggers(trigger_ids, trigger_supervisor, process_registry) do
    Enum.reduce(trigger_ids, 0, fn trigger_id, stopped ->
      case TriggerSupervisor.stop_trigger(trigger_id,
             supervisor: trigger_supervisor,
             process_registry: process_registry
           ) do
        :ok -> stopped + 1
        {:error, :not_found} -> stopped
      end
    end)
  end

  defp build_trigger_config(
         workflow_id,
         trigger,
         index,
         workflow_registry,
         bus,
         backend,
         process_registry
       ) do
    %{
      id: "#{workflow_id}:#{trigger.type}:#{index}",
      workflow_id: workflow_id,
      type: trigger.type,
      patterns: trigger.patterns,
      events: trigger.events,
      schedule: trigger.schedule,
      command: trigger.command,
      debounce_ms: trigger.debounce_ms,
      workflow_registry: workflow_registry,
      bus: bus,
      backend: backend,
      process_registry: process_registry
    }
  end

  defp default_workflow_registry do
    Application.get_env(:jido_workflow, :workflow_registry, WorkflowRegistry)
  end

  defp default_triggers_config_path do
    Application.get_env(
      :jido_workflow,
      :triggers_config_path,
      ".jido_code/workflows/triggers.json"
    )
  end

  defp process_registry(opts) do
    Keyword.get_lazy(opts, :process_registry, fn ->
      Application.get_env(:jido_workflow, :trigger_process_registry, @default_process_registry)
    end)
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_atom_key(map, key)
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
end
