defmodule JidoWorkflow.Workflow.Loader do
  @moduledoc """
  Loads markdown workflow definitions and validates them into typed contracts.
  """

  alias JidoWorkflow.Workflow.Definition
  alias JidoWorkflow.Workflow.MarkdownParser
  alias JidoWorkflow.Workflow.ValidationError
  alias JidoWorkflow.Workflow.Validator

  @spec load_file(Path.t()) :: {:ok, Definition.t()} | {:error, [ValidationError.t()]}
  def load_file(path) when is_binary(path) do
    with {:ok, parsed} <- MarkdownParser.parse_file(path) do
      Validator.validate(parsed)
    end
  end

  @spec load_markdown(binary()) :: {:ok, Definition.t()} | {:error, [ValidationError.t()]}
  def load_markdown(markdown) when is_binary(markdown) do
    with {:ok, parsed} <- MarkdownParser.parse(markdown) do
      Validator.validate(parsed)
    end
  end
end
