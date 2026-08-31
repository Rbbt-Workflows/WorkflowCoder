# WorkflowCoder Design Decisions

## 1. ScoutCoder/ComputerUse Architecture Summary

ScoutCoder is a Scout workflow that `include_workflow ComputerUse`. This gives it:
- All ComputerUse tasks (filesystem, exec, conversion, testing)
- Scout-specific documentation tasks (help_list_repos, help_workflow, etc.)
- Project understanding tasks (summarize_file, explain_code, etc.)

WorkflowCoder extends this chain: `WorkflowCoder → includes ScoutCoder → includes ComputerUse`.

The inheritance pattern is:
```ruby
Workflow.require_workflow "ScoutCoder"
module WorkflowCoder; extend Workflow; end
WorkflowCoder.include_workflow ScoutCoder
```

## 2. Design Alternatives for run_task

### Alternative A: Thin Ruby Wrapper
Run Ruby code via eval/exec and capture output.

**Pros**: Simple, flexible.
**Cons**: Doesn't validate, no structured output, essentially same as `ruby` task. Violates the requirement to "reduce the need for Ruby one-liners."

**Verdict**: Rejected. Does not meet requirements.

### Alternative B: CLI Wrapper
Call `scout workflow task` CLI commands and parse output.

**Pros**: Uses the public CLI interface.
**Cons**: Fragile parsing of CLI output, slower (process overhead), loses structured data, limited error information.

**Verdict**: Rejected. Too fragile and indirect.

### Alternative C: Direct Scout API Integration (Recommended)
Use Scout's internal Workflow/Step/Task APIs directly within the task block:
- `Workflow.require_workflow` to load
- `workflow.tasks` to validate
- `workflow.job` to create steps
- `step.run` to execute
- `step.info` for diagnostics
- `step.files` for artifacts

**Pros**: Full access to structured data, native Scout integration, no parsing needed, comprehensive error information, clean diagnostics.

**Cons**: Tightly coupled to Scout internals (but this is acceptable since WorkflowCoder IS a Scout workflow).

**Verdict**: Selected. Best fit for the requirements.

## 3. Recommended API for run_task

### Inputs
- `workflow` (string, required): Workflow name (e.g., "ComputerUse", "ScoutCoder")
- `task` (string, required): Task name to execute
- `inputs` (json, default {}): Hash of input name => value
- `clean` (boolean, default false): Clean job before running
- `recursive_clean` (boolean, default false): Clean all dependencies
- `stream` (boolean, default false): Stream output (for streaming tasks)

### Output (JSON)
```json
{
  "status": "done|error|aborted|waiting",
  "workflow": "WorkflowName",
  "task": "task_name",
  "execution_time": 1.234,
  "output": "<result value or summary>",
  "output_type": "string|array|json|...",
  "job_path": "/path/to/result",
  "files": ["/path/to/file1", "/path/to/file2"],
  "warnings": ["Unknown input 'foo' ignored"],
  "messages": ["Step started", "Step done"],
  "exception_class": "RuntimeError",
  "exception_message": "Something went wrong",
  "backtrace_summary": ["file.rb:10:in `method'"],
  "dependencies": ["dep_task_1", "dep_task_2"],
  "error_phase": "load_workflow|task_validation|input_validation|execution"
}
```

### Key Design Decisions

1. **Input name is `task` not `task_name`**: Shorter, more natural for agents. No conflict with Scout DSL since we're inside the block.

2. **Symbol key conversion**: JSON inputs arrive with string keys. We convert to symbols for Scout compatibility using `transform_keys(&:to_sym)`.

3. **Exception capture at all phases**: Each phase (load, validate, execute) has its own rescue clause with `error_phase` field for diagnostics.

4. **Output serialization**: Try to preserve native type; fall back to `.to_s` for non-serializable objects. Include `output_type` hint.

5. **No new classes or abstractions**: Uses pure Hash literals. No wrapper classes, no new modules, follows Scout's "annotate, don't wrap" principle.

## 4. Additional Tools

### Implemented
- **list_tasks**: Discover available tasks in any workflow with their input specs
- **task_inputs**: Get detailed input specifications including recursive (dependency) inputs
- **run_task**: Execute any workflow task with structured diagnostics
- **clean_job**: Clean cached results for specific task + inputs
- **job_info**: Inspect job status without running

### Considered but Deferred
- **trace_dependencies**: `Step.prov_report` is available via run_task output already
- **validate_inputs_only**: run_task already validates before execution; standalone validation adds marginal value
- **job_log**: Scout's `step.info[:messages]` already captured in run_task/job_info
- **install_workflow**: `Workflow.require_workflow` already auto-installs; standalone tool unnecessary

## 5. Architectural Justifications

### Why define tasks in lib/WorkflowCoder/tasks/ (not inline in workflow.rb)
Scout convention separates workflow declaration (workflow.rb) from task definitions (lib/). This keeps workflow.rb clean and allows task files to be loaded in dependency order.

### Why use :json return type
Scout's :json type serializes Ruby Hash/Array to JSON automatically. This gives agents structured, parseable output without manual JSON.generate calls. Confirmed valid by ComputerUse's bash/ruby/python tasks using the same pattern.

### Why not create a Struct or Result class
Scout's design principle "Annotate, don't wrap" means we should return plain Hashes, not wrapper objects. Plain Hashes serialize cleanly to JSON and agents can access fields by key. A Result class would add an abstraction with no benefit.

### Why rescue Exception (not StandardError)
During task execution, any error type can occur (including SystemExit, Interrupt in some cases). We catch broadly to ensure structured output is always returned, then re-raise only if necessary. We use `rescue Exception` in the execution phase but use more specific rescues for validation phases.
