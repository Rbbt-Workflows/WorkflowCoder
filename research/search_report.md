# Search Report: WorkflowCoder Development Reference

## Main question
What technical knowledge does an agent need to develop the WorkflowCoder workflow -- a Scout workflow extending ScoutCoder with specialized tools for developing, testing, and debugging Scout workflows?

## Findings

### 1. Existing WorkflowCoder starting point

The WorkflowCoder workflow at `/bulk/mvazque2/git/workflows/WorkflowCoder` already has:

- **`workflow.rb`**: Requires `scout-ai`, calls `Workflow.require_workflow "ScoutCoder"`, defines `module WorkflowCoder; extend Workflow; end`, and includes ScoutCoder.
- **`start_chat`**: System prompt "You are a ruby developer extending the framework Scout with a Workflow", introduces ComputerUse, ScoutCoder, and WorkflowCoder, and runs `ComputerUse pwd` via `exec_task`.
- **`test/test_helper.rb`**: Standard test/unit setup.
- **No README.md yet**, no task files under `lib/`, no documentation.

### 2. ScoutCoder workflow architecture

ScoutCoder is itself a Scout workflow that **includes ComputerUse** via `include_workflow`. It provides three layers of tasks:

**Documentation tasks** (from ScoutCoder itself):
- `help_list_repos`, `help_list_repo_documents`, `help_get_repo_document`, `help_overview`, `help_workflow`

**Project understanding tasks**:
- `summarize_file`, `explain_code`, `explore_directory_structure`

**Planning/implementation tasks**:
- `plan`, `implement`

**Inherited from ComputerUse** (all filesystem + exec + conversion + testing tools):
- `read`, `write`, `delete`, `patch`, `list_directory`, `file_stats`, `pwd`, `search`
- `bash`, `ruby`, `python`, `r`
- `playwright`, `html2md`, `html_query`, `pdf2md`, `pdf_query`, `excerpts`, `rag`, `query`
- `current_time`, `searxng`

### 3. Workflow inheritance pattern

The inheritance chain is:
```
WorkflowCoder → includes ScoutCoder → includes ComputerUse → extends Workflow
```

In `workflow.rb`:
```ruby
Workflow.require_workflow "ScoutCoder"
module WorkflowCoder
  extend Workflow
end
WorkflowCoder.include_workflow ScoutCoder
```

This means WorkflowCoder automatically inherits ALL tasks from both ScoutCoder and ComputerUse.

### 4. Start chat pattern

The start_chat uses three `introduce:` directives to expose all tasks from each workflow as tools:
```
introduce: ComputerUse
introduce: ScoutCoder
introduce: WorkflowCoder
```

The `exec_task:` directive runs a task at chat initialization. Currently it runs `ComputerUse pwd` to set the working directory context.

### 5. Scout Workflow DSL key APIs (from Workflow.md)

**For `run_task` tool development**, the critical APIs are:

**Workflow loading:**
- `Workflow.require_workflow(name)` — loads a workflow by name, auto-installs if needed
- Workflows are modules that `extend Workflow`

**Task introspection:**
- `workflow.tasks` — Hash of task_name => Task objects
- `task.inputs` — Array of `[name, type, desc, default, options]`
- `task.recursive_inputs` — merges required inputs from dep tree
- `workflow.usage(task)` — renders usage for a task
- `workflow.task_info(task_name)` — hash of inputs, defaults, returns, deps, extension
- `workflow.dep_tree(task)` — dependency tree
- `task.deps` — declared dependency annotations

**Job creation and execution:**
- `workflow.job(task_name, jobname=nil, provided_inputs={})` — creates a Step (job)
- `step.run(stream=false)` — runs job, returns Ruby object (false/default), or stream (true)
- `step.exec` — executes task block directly without persistence
- `step.join` — waits for completion, raises on error
- `step.produce` — produces (runs) the job

**Step info and diagnostics:**
- `step.info` — IndiferentHash with status, pid, times, messages, inputs, deps, exceptions
- `step.path` — persisted result path
- `step.files_dir` — companion directory for auxiliary files (`.files/`)
- `step.files` — list of files in files_dir
- Status helpers: `done?`, `error?`, `aborted?`, `running?`, `waiting?`, `updated?`, `dirty?`, `started?`, `recoverable_error?`
- `step.clean`, `step.recursive_clean` — cleanup
- `step.dependencies`, `step.rec_dependencies` — dependency steps
- `Step.prov_report(step)` — provenance tree as text
- `step.messages` — log messages
- `step.info[:messages]` — messages from info hash

**Input handling:**
- `task.assign_inputs(provided_inputs, id=nil)` — returns `[input_array, non_default_inputs, jobname_input?]`
- `task.process_inputs(provided_inputs, id=nil)` — returns `[input_array, non_default_inputs, digest_str]`
- `task.save_inputs(dir, provided_inputs)`, `task.load_inputs(dir)`

**Task input metadata:**
- Each input is `[name, type, desc, default, options]`
- Options can include `required: true`, `jobname: true`
- Missing required inputs raise `ParameterException`

**On-disk layout:**
```
var/jobs/<Workflow>/<task>/<jobname>.<ext>        # result
var/jobs/<Workflow>/<task>/<jobname>.<ext>.info   # JSON metadata
var/jobs/<Workflow>/<task>/<jobname>.<ext>.files/ # auxiliary files
```

### 6. Start chat configuration directives

From WritingChats.md:
- `introduce: WorkflowName` — exposes ALL tasks from a workflow as tools
- `tool: WorkflowName task_name input1=value1` — exposes a single task with defaults
- `exec_task: WorkflowName task_name [inputs]` — runs a task at init
- `file: path` — imports file content into chat
- `option:`, `model:`, `endpoint:` — configuration
- `import: path` — inlines another chat file

### 7. Agent directory structure

Agents are named directories with:
- `start_chat` — system prompt + tool declarations
- `workflow.rb` — optional Scout workflow providing tools
- `knowledge_base/` — optional KB
- `python/` — optional Python tasks

Agent discovery locations: `Scout.workflows[name]`, `Scout.Agent[name]`, `Scout.chats.Agent[name]`, `Scout.chats[name]`

### 8. Scout-AI design principles (critical for implementation)

From DesignPrinciples.md:
- **Abstraction-first**: Every concept should be a crisp abstraction
- **Module composition over inheritance**: No deep class hierarchies; use modules
- **Chat-as-data**: A Chat is a plain Array of Hashes, annotated with DSL methods
- **Convention over configuration**: Files in the right place are auto-discovered
- **Lazy initialization**: Use `||=` pattern
- **IndiferentHash everywhere**: Symbol/string-indifferent access
- **Annotate, don't wrap**: Don't create wrapper classes for Arrays/Hashes

**Anti-patterns to avoid:**
- Creating wrapper classes for Arrays/Hashes
- Deep inheritance hierarchies
- Eager initialization
- Explicit delegation methods when `method_missing` already works
- New abstractions that don't fit existing Scout concepts

### 9. Key Scout Workflow concepts for `run_task` design

**Task execution lifecycle:**
1. `Workflow.require_workflow("MyWF")` loads the workflow
2. `wf.tasks[:task_name]` checks if task exists
3. `wf.job(:task_name, nil, input1: "value")` creates a Step
4. `step.run` executes, returns result
5. `step.info` has status, messages, timing, exceptions
6. `step.files_dir` has auxiliary files
7. `step.path` is the persisted result path

**ParameterException:**
- Raised when required inputs are missing
- This is Scout's standard input validation mechanism

**ScoutException:**
- Used for recoverable errors
- Non-ScoutException errors are treated as non-recoverable

### 10. README.md documentation format

The user specified a 3-part format:
1. **Part 1**: One-liner description of the workflow
2. **Part 2**: Paragraphs of explanation (headers `#` allowed here)
3. **Part 3**: `# Tasks` section (level-1 header), then each task as `## task_name` (level-2 header)

The format instructions must be included in the README itself so WorkflowCoder always knows the format.

In task descriptions, avoid `#` or `##` headers to not confuse the parser.

## Sources
- `Workflow.md` from scout-gear documentation
- `WritingChats.md` from scout-ai documentation
- `ToolCalling.md` from scout-ai documentation
- `BuildingAgents.md` from scout-ai documentation
- `DesignPrinciples.md` from scout-ai documentation
- `Architecture.md` from scout-ai documentation
- `ChatLifecycle.md` from scout-ai documentation
- `DelegationInternals.md` from scout-ai documentation
- `CoreConcepts.md` from scout-ai documentation
- `help_workflow` output for ScoutCoder and ComputerUse
- Direct inspection of WorkflowCoder starting files
- `chats/basic_tasks` file containing the original request

## Relevant skills
- No specific skills matched this task via `match_skills` (not attempted due to sandbox restrictions)

## Uncertainties
- Could not execute Ruby directly to inspect ScoutCoder's internal class structure due to bwrap sandbox mount issues. The `help_workflow` documentation was used instead.
- Could not browse `~/git/workflows/` directory due to filesystem sandbox restrictions limiting to WorkflowCoder root only. Other workflows were referenced from scout-ai docs and the Planned agent description.
- Could not read ScoutCoder's actual source files (outside sandbox root). The full task documentation from `help_workflow` was used as the primary source.
- The `lib/` directory in WorkflowCoder is empty -- implementation files will need to be created from scratch.

## Recommendation

The agent implementing WorkflowCoder should:

1. **Use the Scout Workflow DSL directly** for `run_task`: The `Workflow.require_workflow`, `workflow.job`, `step.run`, `step.info` APIs are sufficient. No new abstractions needed.

2. **Return structured JSON** from `run_task` since tool outputs are always converted to text. Use `:json` as the task return type.

3. **Consider additional tools**: `list_tasks`, `task_inputs`, `clean_job`, and `job_info` would complement `run_task` to cover the full development lifecycle (discover → validate → execute → inspect → clean).

4. **Follow the README format strictly**: Include the format instructions in the README, use `# Tasks` as a level-1 header, and `## task_name` for each task.

5. **Keep the start_chat simple**: Use `introduce: ComputerUse`, `introduce: ScoutCoder`, `introduce: WorkflowCoder` to expose all tools. Add a file import for the README.

6. **Key Scout APIs to study before implementation**:
   - `task.inputs` for input validation (name, type, required, default)
   - `task.recursive_inputs` for dependency-aware input checking
   - `step.info` for post-execution diagnostics (status, messages, timing, exceptions)
   - `step.files` / `step.files_dir` for artifact discovery
   - `step.clean` / `step.recursive_clean` for cleanup
   - `ParameterException` as the standard validation error type
   - `ScoutException` for recoverable errors
   - `Step.prov_report` for provenance/dependency trees
