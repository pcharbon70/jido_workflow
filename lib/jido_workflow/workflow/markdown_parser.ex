defmodule JidoWorkflow.Workflow.MarkdownParser do
  @moduledoc """
  Parses markdown workflow files into normalized workflow attribute maps.

  Expected structure:
  - YAML frontmatter (`--- ... ---`)
  - `## Steps` with `### step_name` subsections
  - optional `## Error Handling`
  - optional `## Return`
  """

  alias JidoWorkflow.Workflow.ValidationError

  @spec parse_file(Path.t()) :: {:ok, map()} | {:error, [ValidationError.t()]}
  def parse_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, markdown} ->
        parse(markdown)

      {:error, reason} ->
        {:error, [error(["file"], :read_failed, "failed to read file: #{inspect(reason)}")]}
    end
  end

  @spec parse(binary()) :: {:ok, map()} | {:error, [ValidationError.t()]}
  def parse(markdown) when is_binary(markdown) do
    with {:ok, frontmatter, body} <- split_frontmatter(markdown),
         {:ok, attrs} <- decode_yaml(frontmatter, ["frontmatter"]),
         {:ok, sections} <- split_sections(body) do
      {:ok, build_definition_map(attrs, sections)}
    end
  end

  def parse(other) do
    {:error, [error([], :invalid_type, "markdown must be a string, got: #{inspect(other)}")]}
  end

  defp split_frontmatter(markdown) do
    if String.starts_with?(markdown, "---\n") do
      case String.split(markdown, "\n---\n", parts: 2) do
        [<<"---\n", frontmatter::binary>>, body] ->
          {:ok, frontmatter, body}

        _ ->
          {:error,
           [error(["frontmatter"], :missing_frontmatter, "invalid or unclosed YAML frontmatter")]}
      end
    else
      {:error,
       [
         error(
           ["frontmatter"],
           :missing_frontmatter,
           "workflow markdown must start with YAML frontmatter"
         )
       ]}
    end
  end

  defp decode_yaml(yaml, path) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, other} ->
        {:error, [error(path, :invalid_type, "expected YAML object, got: #{inspect(other)}")]}

      {:error, reason} ->
        {:error, [error(path, :yaml_error, "failed to parse YAML: #{inspect(reason)}")]}
    end
  end

  defp split_sections(body) do
    lines = String.split(body, "\n")

    {sections, current, buffer} =
      Enum.reduce(lines, {%{}, nil, []}, fn line, {acc, active, content} ->
        case Regex.run(~r/^##\s+(.+)\s*$/, line) do
          [_, title] ->
            {store_section(acc, active, content), title, []}

          _ ->
            {acc, active, content ++ [line]}
        end
      end)

    {:ok, store_section(sections, current, buffer)}
  rescue
    e ->
      {:error,
       [error(["body"], :parse_error, "failed to split markdown sections: #{inspect(e)}")]}
  end

  defp build_definition_map(frontmatter_attrs, sections) do
    steps = parse_steps(Map.get(sections, "steps", ""))
    error_handling = parse_error_handling(Map.get(sections, "error_handling", ""))
    return_config = parse_return(Map.get(sections, "return", ""))

    frontmatter_attrs
    |> Map.put("steps", steps)
    |> Map.put("error_handling", error_handling)
    |> maybe_put_return(return_config)
  end

  defp maybe_put_return(attrs, nil), do: attrs
  defp maybe_put_return(attrs, value), do: Map.put(attrs, "return", value)

  defp parse_steps(section_body) do
    section_body
    |> split_h3_blocks()
    |> Enum.map(fn {name, block_lines} ->
      props =
        parse_bold_property_list(block_lines)
        |> Map.put("name", String.trim(name))

      normalize_step(props)
    end)
  end

  defp parse_error_handling(section_body) do
    section_body
    |> split_h3_blocks()
    |> Enum.map(fn {name, block_lines} ->
      parse_bold_property_list(block_lines)
      |> Map.put("handler", String.trim(name))
    end)
  end

  defp parse_return(""), do: nil

  defp parse_return(section_body) do
    parsed = parse_bold_property_list(String.split(section_body, "\n"))
    if map_size(parsed) == 0, do: nil, else: parsed
  end

  defp split_h3_blocks(text) do
    lines = String.split(text, "\n")

    {blocks, current_title, current_lines} =
      Enum.reduce(lines, {[], nil, []}, fn line, {acc, title, content} ->
        case Regex.run(~r/^###\s+(.+)\s*$/, line) do
          [_, h3_title] ->
            {store_h3_block(acc, title, content), h3_title, []}

          _ ->
            {acc, title, append_h3_line(content, title, line)}
        end
      end)

    if is_nil(current_title) do
      []
    else
      blocks ++ [{current_title, current_lines}]
    end
  end

  defp store_section(sections, nil, _content), do: sections

  defp store_section(sections, heading, content) do
    Map.put(sections, normalize_heading(heading), Enum.join(content, "\n"))
  end

  defp store_h3_block(blocks, nil, _content), do: blocks
  defp store_h3_block(blocks, title, content), do: blocks ++ [{title, content}]

  defp append_h3_line(content, nil, _line), do: content
  defp append_h3_line(content, _title, line), do: content ++ [line]

  defp parse_bold_property_list(lines) do
    do_parse_properties(lines, 0, %{})
  end

  defp do_parse_properties(lines, index, acc) when index >= length(lines), do: acc

  defp do_parse_properties(lines, index, acc) do
    line = Enum.at(lines, index) |> to_string() |> String.trim_trailing()

    case Regex.run(~r/^- \*\*([^*]+)\*\*:\s*(.*)$/, String.trim_leading(line)) do
      [_, raw_key, rest] ->
        key = normalize_heading(raw_key)

        cond do
          rest == "|" ->
            {block_lines, next_index} = collect_nested_lines(lines, index + 1)
            block = block_lines |> dedent_lines(2) |> Enum.join("\n") |> String.trim_trailing()
            do_parse_properties(lines, next_index, Map.put(acc, key, block))

          rest != "" ->
            do_parse_properties(lines, index + 1, Map.put(acc, key, parse_scalar(rest)))

          true ->
            {nested, next_index} = collect_nested_lines(lines, index + 1)
            value = parse_nested_value(key, nested)
            do_parse_properties(lines, next_index, Map.put(acc, key, value))
        end

      _ ->
        do_parse_properties(lines, index + 1, acc)
    end
  end

  defp collect_nested_lines(lines, index) do
    do_collect_nested_lines(lines, index, [])
  end

  defp do_collect_nested_lines(lines, index, acc) when index >= length(lines) do
    {acc, index}
  end

  defp do_collect_nested_lines(lines, index, acc) do
    line = Enum.at(lines, index) |> to_string()

    cond do
      String.trim(line) == "" ->
        do_collect_nested_lines(lines, index + 1, acc ++ [line])

      String.starts_with?(line, "  ") ->
        do_collect_nested_lines(lines, index + 1, acc ++ [line])

      true ->
        {acc, index}
    end
  end

  defp parse_nested_value(_key, []), do: nil

  defp parse_nested_value(key, nested_lines) do
    yaml = nested_lines |> dedent_lines(2) |> Enum.join("\n")

    case YamlElixir.read_from_string(yaml) do
      {:ok, value} -> normalize_nested_value(key, value)
      {:error, _} -> fallback_parse_nested_value(nested_lines)
    end
  end

  defp normalize_nested_value("inputs", value), do: coerce_pairs_list_to_map(value)
  defp normalize_nested_value("depends_on", value), do: coerce_to_string_list(value)
  defp normalize_nested_value("outputs", value), do: coerce_to_string_list(value)
  defp normalize_nested_value(_key, value), do: value

  defp fallback_parse_nested_value(nested_lines) do
    nested_lines
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^- ([^:]+):\s*(.+)$/, line) do
        [_, key, value] -> Map.put(acc, String.trim(key), parse_scalar(value))
        _ -> acc
      end
    end)
  end

  defp parse_scalar(value) do
    value = String.trim(value)

    cond do
      value == "true" -> true
      value == "false" -> false
      Regex.match?(~r/^\d+$/, value) -> String.to_integer(value)
      list_literal?(value) -> parse_list_literal(value)
      quoted_literal?(value) -> strip_quotes(value)
      true -> value
    end
  end

  defp list_literal?(value), do: String.starts_with?(value, "[") and String.ends_with?(value, "]")

  defp parse_list_literal(value) do
    value
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&strip_quotes(String.trim(&1)))
  end

  defp quoted_literal?(value) do
    (String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
      (String.starts_with?(value, "'") and String.ends_with?(value, "'"))
  end

  defp strip_quotes(value) do
    value
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp normalize_step(step) do
    step
    |> maybe_update("depends_on", &coerce_to_string_list/1)
    |> maybe_update("outputs", &coerce_to_string_list/1)
    |> maybe_update("inputs", &coerce_pairs_list_to_map/1)
  end

  defp maybe_update(map, key, updater) do
    if Map.has_key?(map, key) do
      Map.update!(map, key, updater)
    else
      map
    end
  end

  defp coerce_to_string_list(nil), do: nil
  defp coerce_to_string_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp coerce_to_string_list(other), do: [to_string(other)]

  defp coerce_pairs_list_to_map(nil), do: nil
  defp coerce_pairs_list_to_map(map) when is_map(map), do: map

  defp coerce_pairs_list_to_map(list) when is_list(list) do
    if Enum.all?(list, &(is_map(&1) and map_size(&1) == 1)) do
      Enum.reduce(list, %{}, fn item, acc ->
        [{key, value}] = Map.to_list(item)
        Map.put(acc, to_string(key), value)
      end)
    else
      list
    end
  end

  defp coerce_pairs_list_to_map(other), do: other

  defp dedent_lines(lines, spaces) do
    prefix = String.duplicate(" ", spaces)

    Enum.map(lines, fn line ->
      if String.starts_with?(line, prefix) do
        String.replace_prefix(line, prefix, "")
      else
        line
      end
    end)
  end

  defp normalize_heading(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp error(path, code, message) do
    %ValidationError{path: path, code: code, message: message}
  end
end
