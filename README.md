Agent workflow specialized in developing, testing, debugging, and maintaining Scout workflows

WorkflowCoder extends ScoutCoder (which extends ComputerUse) to provide
specialized tools for Scout workflow development. It introduces a
development-oriented interface for executing workflow tasks, inspecting job
state, validating inputs, and managing job caches -- all with structured
output suitable for agent reasoning.

The key principle is that agents should almost never need to construct Ruby
one-liners or bash commands to test workflows. Instead, they use the
`run_task` tool, which loads the workflow, validates the task and its inputs,
executes it, and returns a structured JSON response with execution status,
output value, generated files, warnings, exception summaries, timing, job
directory, and log messages.

The workflow inherits all capabilities from ScoutCoder and ComputerUse:

- ComputerUse: `read`, `write`, `delete`, `patch`, `list_directory`,
  `file_stats`, `pwd`, `search`, `bash`, `ruby`, `python`, `r`, `playwright`,
  `html2md`, `html_query`, `docx2md`, `current_time`, `searxng`, and more.
- ScoutCoder: `help_list_repos`, `help_list_repo_documents`,
  `help_get_repo_document`, `help_overview`, `help_workflow`,
  `summarize_file`, `explain_code`, `explore_directory_structure`, `plan`,
  `implement`.

# Workflow development methodology

When developing or debugging a Scout workflow, follow this iterative cycle:

1. **Discover**: Use `list_tasks` to see what tasks exist in a workflow and
   their input specifications.
2. **Understand**: Use `task_inputs` to get detailed input specs including
   recursive inputs propagated from dependencies.
3. **Test**: Use `run_task` to execute a task with specific inputs. The
   structured output tells you the status, output, warnings, files, timing,
   and any exceptions -- all without writing Ruby code.
4. **Inspect**: Use `job_info` to check the status of a previously executed
   (or failed) job without re-running it.
5. **Clean**: Use `clean_job` to clear cached results before re-running after
   code changes.

Example workflow for testing a task:

    # First, discover what's available
    run_task(workflow="ComputerUse", task="list_tasks")  # or just use list_tasks

    # Get input specs for a specific task
    task_inputs(workflow="ComputerUse", task="current_time")

    # Run the task
    run_task(workflow="ComputerUse", task="current_time", inputs={})

    # Check job info without re-running
    job_info(workflow="ComputerUse", task="current_time", inputs={})

# Common Scout workflow patterns

A Scout workflow is a Ruby module that extends `Workflow`. Tasks are declared
using the `task` DSL method. Here is a minimal example:

    module MyWorkflow
      extend Workflow

      desc "Greet someone"
      input :name, :string, "Name to greet", "World"
      task :greet => :string do |name|
        "Hello, #{name}!"
      end
    end

Key patterns:

- **Input declaration**: `input :name, :type, "description", default, options`
  where options can include `required: true` or `jobname: true`.
- **Task types**: `:string`, `:integer`, `:float`, `:boolean`, `:array`,
  `:json`, `:tsv`, `:file`, `:stream`.
- **Dependencies**: Use `dep` or inline dependencies in the task hash.
- **File tasks**: `task :my_task => :file do ... end` produces a file on disk.
- **Extension**: `task :my_task => :string` specifies the return type.

# Common pitfalls

- **String vs symbol keys**: Scout tasks expect symbol keys for inputs.
  `run_task` handles this conversion automatically.
- **Cached results**: If you change code but don't clean, `step.run` returns
  the cached result. Use `clean: true` in `run_task` or use `clean_job`.
- **Missing required inputs**: Scout raises `ParameterException` when required
  inputs are missing. `run_task` catches this and returns it as structured
  JSON with `error_phase: "input_validation"`.
- **Streaming tasks**: Some tasks return streams. Use `stream: true` in
  `run_task` if the task supports streaming output.
- **Dependency resolution**: Tasks with dependencies may need inputs that are
  forwarded from upstream tasks. Use `task_inputs` with the recursive_inputs
  field to see all accepted inputs.

# Best practices

- Always use `run_task` instead of `ruby` or `bash` to test workflow tasks.
- Use `list_tasks` before guessing task names.
- Use `task_inputs` to understand what inputs a task accepts.
- Use `clean: true` when re-running after code changes.
- Read the `warnings` array in `run_task` output -- it catches typos in input
  names and missing required inputs before execution.
- Check `error_phase` to understand where a failure occurred: `load_workflow`,
  `task_validation`, `input_validation`, `job_creation`, or `execution`.
- Exceptions of the class ScoutException, such as ParameterException are
  considered controlled and understood, and are preferred for foreseeable
  errors. Otherwise they are considered uncontrolled and will be considered
  potentially recoverable by retrying the job.

# How to write Scout documentation (README.md)

Documentation files for Scout workflows are written in markdown and contain
three broad parts:

1. A one-liner description of the workflow as a whole.
2. One or more paragraphs of description on the workflow and its
   functionalities, including (if relevant) examples or installation
   instructions. Header indicators like `#` or `##` are allowed in this
   section.
3. A section describing the different tasks.

The third section, where tasks are described, follows a particular format. It
begins with a new line like this:

    # Tasks

Note the `#` character indicating it is a level 1 header.

This is followed by the different task descriptions. Each task description
starts with the name of the task, a one-liner description of what it does,
followed by one or more paragraphs of explanation on the task, including (if
pertinent) relevant implementation details. Like this example:

    ## example_task
    Perform an example task

    If this were a real task here you would find the details.

    There could also be a second paragraph.

Note the `##` characters indicating it is a level 2 header.

In the task descriptions, avoid using header indicators like `#` or `##` to
avoid confusing the parser. In the section containing the broad description of
the workflow, header indicators are allowed.

# Tasks

## list_tasks
List all tasks available in a workflow

Given a workflow name, this task loads the workflow using
`Workflow.require_workflow`, iterates over all declared tasks, and returns a
JSON array. Each entry contains the task name, description, result type,
declared inputs (with name, type, description, default, and required flag),
and declared dependencies.

This is the primary discovery tool. Use it before calling `run_task` to
confirm that the task name is correct and to see what inputs are expected.

Example output structure:

    [
      {
        "name": "current_time",
        "description": "Return current time as string",
        "type": "string",
        "inputs": [],
        "dependencies": []
      }
    ]

## task_inputs
Get detailed input specifications for a single workflow task

Given a workflow name and a task name, this task returns a JSON object with
both the direct inputs (declared on the task itself) and the recursive inputs
(inputs propagated from upstream dependencies via `dep` declarations).

The recursive_inputs field is particularly useful for tasks that have
dependencies, since Scout automatically forwards qualifying inputs to upstream
tasks. Without checking recursive_inputs, you might miss inputs that the task
actually accepts.

Example output structure:

    {
      "workflow": "ComputerUse",
      "task": "read",
      "description": "Read a file ...",
      "result_type": "string",
      "direct_inputs": [
        { "name": "path", "type": "string", "description": "...", "required": true }
      ],
      "recursive_inputs": [...]
    }

## run_task
Execute a workflow task and return structured diagnostics

This is the primary development tool. It loads the target workflow, validates
that the task exists, checks inputs for common mistakes (typos, missing
required inputs), optionally cleans cached results, executes the task, and
returns a comprehensive JSON object with all execution details.

Inputs:

- `workflow` (string, required): Name of the workflow to load.
- `task` (string, required): Name of the task to run.
- `inputs` (json, default {}): Hash of input name to value pairs. Keys may be
  strings or symbols; they are converted to symbols automatically.
- `clean` (boolean, default false): Clean this job's cached result before
  running.
- `recursive_clean` (boolean, default false): Clean all dependency caches
  before running.
- `stream` (boolean, default false): Pass `true` to `step.run` for streaming
  tasks.

The returned JSON contains:

- `status`: Execution status (done, error, aborted, waiting, etc.)
- `output`: The return value of the task (serialized, truncated if very long)
- `output_type`: Type hint for the output (string, array, hash, nil, etc.)
- `execution_time`: Wall-clock seconds for the execution phase
- `job_path`: Filesystem path to the job result
- `files`: Array of file paths generated in the job's files_dir
- `warnings`: Non-fatal issues (unknown inputs, missing required inputs)
- `messages`: Log messages from step.info
- `exception_class`: Ruby exception class name if an error occurred
- `exception_message`: Human-readable exception message
- `backtrace_summary`: First 10-15 lines of the backtrace for debugging
- `dependencies`: List of dependency job names/paths
- `error_phase`: Where the error occurred (load_workflow, task_validation,
  input_validation, job_creation, execution)

The task never raises exceptions to the caller. All errors are captured and
returned as structured JSON. This makes it safe for agents to call without
worrying about unhandled exceptions.

Example usage:

    run_task(
      workflow="ComputerUse",
      task="current_time",
      inputs={}
    )

Example response (abbreviated):

    {
      "status": "done",
      "output": "2026-08-06 12:34:56 +0000",
      "output_type": "string",
      "execution_time": 0.001,
      "files": [],
      "warnings": []
    }

## clean_job
Clean cached results for a workflow task

Given a workflow name, task name, and optional inputs, this task creates the
job (without running it) and cleans its cached result. With `recursive: true`,
it also cleans all dependency results.

Use this before re-running a task after modifying its code, or to free disk
space from large intermediate results.

Example usage:

    clean_job(
      workflow="ComputerUse",
      task="current_time",
      inputs={}
    )

## job_info
Retrieve structured info about a job without running it

Given a workflow name, task name, and optional inputs, this task creates the
job (without running it) and reads its `step.info` metadata. This is useful
for checking the status of a previously executed job, examining messages,
checking timing, or inspecting exception details -- all without triggering a
new execution.

The returned JSON contains:

- `status`: Current job status from step.info
- `messages`: Log messages recorded during previous execution
- `dependencies`: Dependency job names/paths
- `exception`: Exception details if the job previously errored
- `time_started`: When the job was started (if ever)
- `time_done`: When the job completed (if ever)
- `job_path`: Filesystem path to the job result
- `files`: Files in the job's files_dir (if any)

Example usage:

    job_info(
      workflow="ComputerUse",
      task="current_time",
      inputs={}
    )
