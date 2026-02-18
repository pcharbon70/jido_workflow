defmodule JidoWorkflow.Workflow.Actions.ExecuteActionStep do
  @moduledoc """
  Executes compiled action workflow steps.

  Step metadata includes the target action module and input bindings.
  Input bindings support `input:` and `result:` references resolved against
  the current workflow state.
  """

  alias JidoWorkflow.Workflow.ArgumentResolver

  use Jido.Action,
    name: "workflow_execute_action_step",
    description: "Execute a compiled workflow action step",
    schema: [
      step: [type: :map, required: true]
    ]

  @impl true
  def run(%{step: step} = params, _context) do
    state =
      params
      |> extract_runtime_state()
      |> ArgumentResolver.normalize_state()

    with {:ok, step_meta} <- normalize_step(step),
         {:ok, target_module} <- resolve_module(step_meta.module),
         {:ok, resolved_inputs} <- ArgumentResolver.resolve_inputs(step_meta.inputs, state),
         {:ok, result} <- run_action(target_module, resolved_inputs, step_meta) do
      {:ok, ArgumentResolver.put_result(state, step_meta.name, result)}
    end
  end

  defp extract_runtime_state(params) when is_map(params) do
    case fetch(params, "input") do
      nil ->
        params
        |> Map.delete(:step)
        |> Map.delete("step")

      input ->
        input
    end
  end

  defp normalize_step(step) when is_map(step) do
    name = fetch(step, "name")
    module = fetch(step, "module")
    inputs = fetch(step, "inputs")
    timeout_ms = fetch(step, "timeout_ms")

    cond do
      is_nil(name) ->
        {:error, {:invalid_step, "step name is missing"}}

      is_nil(module) ->
        {:error, {:invalid_step, "step module is missing"}}

      true ->
        {:ok,
         %{
           name: to_string(name),
           module: module,
           inputs: inputs,
           timeout_ms: timeout_ms
         }}
    end
  end

  defp normalize_step(other),
    do: {:error, {:invalid_step, "step must be a map, got: #{inspect(other)}"}}

  defp resolve_module(module) when is_atom(module), do: {:ok, module}

  defp resolve_module(module) when is_binary(module) do
    qualified =
      if String.starts_with?(module, "Elixir.") do
        module
      else
        "Elixir." <> module
      end

    try do
      resolved = String.to_existing_atom(qualified)

      if Code.ensure_loaded?(resolved) do
        {:ok, resolved}
      else
        {:error, {:module_not_loaded, module}}
      end
    rescue
      ArgumentError ->
        {:error, {:module_not_loaded, module}}
    end
  end

  defp resolve_module(other), do: {:error, {:invalid_module, other}}

  defp run_action(target_module, inputs, step_meta) do
    opts =
      case step_meta.timeout_ms do
        timeout when is_integer(timeout) and timeout >= 0 -> [timeout: timeout]
        _ -> []
      end

    case Jido.Exec.run(
           target_module,
           atomize_top_level_keys(inputs),
           %{workflow_step: step_meta.name},
           opts
         ) do
      {:ok, result} -> {:ok, result}
      {:ok, result, extra} -> {:ok, %{result: result, extra: extra}}
      {:error, reason} -> {:error, {:action_failed, reason}}
    end
  end

  defp atomize_top_level_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      converted_key =
        case key do
          atom when is_atom(atom) ->
            atom

          binary when is_binary(binary) ->
            try do
              String.to_existing_atom(binary)
            rescue
              ArgumentError -> binary
            end

          other ->
            other
        end

      Map.put(acc, converted_key, value)
    end)
  end

  defp fetch(step, key) when is_map(step) do
    case Map.fetch(step, key) do
      {:ok, value} -> value
      :error -> fetch_atom_key(step, key)
    end
  end

  defp fetch_atom_key(step, key) do
    Enum.find_value(step, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end
end
