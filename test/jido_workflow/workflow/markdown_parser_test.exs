defmodule JidoWorkflow.Workflow.MarkdownParserTest do
  use ExUnit.Case, async: true

  alias JidoWorkflow.Workflow.MarkdownParser
  alias JidoWorkflow.Workflow.ValidationError

  @fixture "/Users/Pascal/code/jido/jido_workflow/test/support/fixtures/workflows/code_review_pipeline.md"

  test "parse_file/1 parses frontmatter and workflow sections" do
    assert {:ok, parsed} = MarkdownParser.parse_file(@fixture)

    assert parsed["name"] == "code_review_pipeline"
    assert parsed["version"] == "1.0.0"
    assert parsed["enabled"] == true
    assert length(parsed["inputs"]) == 2
    assert length(parsed["triggers"]) == 2
    assert length(parsed["steps"]) == 3

    parse_file_step = Enum.find(parsed["steps"], &(&1["name"] == "parse_file"))
    assert parse_file_step["type"] == "action"
    assert parse_file_step["module"] == "JidoCode.Actions.ParseElixirFile"
    assert parse_file_step["inputs"] == %{"file_path" => "`input:file_path`"}
    assert parse_file_step["outputs"] == ["ast", "module_info", "functions"]
  end

  test "parse_file/1 parses nested step fields and return transform" do
    assert {:ok, parsed} = MarkdownParser.parse_file(@fixture)

    ai_review_step = Enum.find(parsed["steps"], &(&1["name"] == "ai_code_review"))
    assert ai_review_step["depends_on"] == ["parse_file"]
    assert ai_review_step["mode"] == "sync"
    assert ai_review_step["timeout_ms"] == 60_000
    assert is_list(ai_review_step["pre_actions"])
    assert is_map(ai_review_step["inputs"])

    assert parsed["return"]["value"] == "ai_code_review"
    assert String.contains?(parsed["return"]["transform"], "fn result ->")
    assert String.contains?(parsed["return"]["transform"], "summary")
  end

  test "parse/1 returns path-aware error when frontmatter is missing" do
    markdown = """
    # No Frontmatter

    ## Steps
    """

    assert {:error, [%ValidationError{} = error]} = MarkdownParser.parse(markdown)
    assert error.code == :missing_frontmatter
    assert error.path == ["frontmatter"]
  end
end
