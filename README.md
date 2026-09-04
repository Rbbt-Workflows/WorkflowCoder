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
    run_task(workflow="ComputerUse", task="current_time")  # or just use list_tasks

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

For submitting and later controlling jobs (blocking, path-only, background
fork, or a no-run preview), see the "Job submission and control" section
under `# Tasks`.

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
  `task_validation`, `input_validation`, `job_creation`, `job_reference`,
  `execution`, or `job_state` (the last one, only from `job_result`, marks a
  state report about an unfinished job, not an exception).
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

In the task descriptions, avoid using header indicators like `#` or `##` to
avoid confusing the parser. In the section containing the broad description of
the workflow, header indicators are allowed.

## Job identity: how a job path is derived

The `job_path`/`short_path` that `preview_job`, `run_task` and `job_info`
report are deterministic functions of the run, which is what makes running by
reference reliable:

- A job using only default inputs is labeled plain `Default`; any non-default
  provided input (or any dependency) turns the label into `Default_<md5>`,
  where the hash covers the non-default inputs and the resolved dependencies.
- File-valued inputs are digested by content, not by path: change the content
  of an input file and the label hash changes, moving the job to a new path
  even though the path string you passed is identical.
- The `.info` file of a job is written only when the job starts running, so
  `preview_job` reporting `info_exists: false` simply means the job was never
  run.
- `short_path` is the three-segment `Workflow/task/name` identifier built from
  the job label, and it is what `job_info` reports; Scout has no `sort_path`
  concept, `short_path` is the accepted form of that identifier and the form
  accepted by `run_task --job`.

## Job submission and control

There is one submission point -- `run_task` -- with four ways to use it, and a
family of control tasks that address an already-submitted job by reference
(full job path, `Workflow/task/name` short_path, or `task/name` plus the
`workflow` option: exactly the reference forms that running by reference
accepts).

Submission modes:

| Mode | Where | Blocks | Loads result | Returns | scout-camp equivalent |
|------|-------|--------|--------------|---------|----------------------|
| `wait_result` | `run_task` (default, no `mode` needed) | yes | yes | full diagnostics + `output` | `initiate_step` sync case, `step.run` (`lib/scout/sinatra/base.rb:66-67`) then `serve_step` loading the payload (`base.rb:90-95`) |
| `wait_path`   | `run_task --mode wait_path` | yes | no | diagnostics with `output: null`, `output_type: "path_receipt"` | `initiate_step` sync run (`base.rb:66-67`) with the final `step.join` but no `step.load` (`base.rb:76`) |
| `fork`        | `run_task --mode fork` | no | no | diagnostics with `submitted: true`, `pid`, `pid_alive` | `initiate_step` async case: `step.fork unless step.started?` (`base.rb:68-69`), `Open.wait_for(step.path, timeout: 0.5)` (`base.rb:74`) |
| preview       | `preview_job` | no | no | the would-be path; writes no `.info`, runs nothing | none -- camp has no dry-run endpoint; this is a WorkflowCoder addition |

- `wait_result` is byte-for-byte the historical behavior and remains the
  default: omit `mode` and nothing changes.
- `wait_path` runs the job to completion in the caller's process but with
  `step.run(:no_load)`, so the result is never deserialized -- useful for
  tasks whose payload is huge or binary. On error it returns the structured
  error as usual and still includes the path.
- `fork` mirrors scout-camp's asynchronous `initiate_step`
  (`lib/scout/sinatra/base.rb:57-79` in the scout-camp checkout): the job runs
  in a detached child via the engine's own `Step#fork`, and the task returns
  in well under the task duration. The child survives the task returning:
  `Step#fork` (scout-gear `scout/workflow/step.rb:291-309`) detaches the child
  and the engine registers no at_exit hook for it. Poll with `job_status`,
  fetch with `job_result`. Note that a forked job that is killed by TERM
  records an `:error` state in its own info; see the `job_stop` convention
  below.

  Execution-environment caveat: `fork` relies on the detached child
  outliving the task process. Two facts bound this (see
  `tmp/probe-verdicts.md`): (1) `scout workflow task` adds no sandbox of its
  own around the task process, and parent-exit survival of the detached
  child is probe-verified even when the task process itself runs inside a
  bwrap `--die-with-parent` PID-namespace sandbox; (2) the detached child
  shares its parent's PID namespace, so if that whole enclosing sandbox is
  torn down while the job is still running (teardown-on-exit), the kernel
  kills the background job with it and a `fork` receipt would then refer to
  a job that dies shortly after. Full sandbox-teardown behavior is
  UNVERIFIED (no bypass was attempted); only parent-exit survival is
  probe-verified. Under a harness that tears down its sandbox on exit, use
  `wait_path` or `wait_result` instead.

- `preview_job` is the fourth mode: it derives the path without running
  anything at all.

`mode` composes with the `job` reference input (re-run a referenced job in any
mode) and with `workflow`/`task`/`inputs` as usual. An invalid `mode` value
returns the usual structured error with `error_phase: "input_validation"`.

Ruby, all four modes (executed verbatim; outputs below):

    require "scout"
    Workflow.require_workflow "WFTestAI"   # fixture workflow

    preview = WorkflowCoder.job(:preview_job, nil, workflow: "WFTestAI",
                                task: "slow_task", inputs: {"seconds" => 3}).run

    blocked = WorkflowCoder.job(:run_task, nil, workflow: "WFTestAI",
                                task: "slow_task", inputs: {"seconds" => 3},
                                mode: "wait_path").run

    bg = WorkflowCoder.job(:run_task, nil, workflow: "WFTestAI",
                           task: "slow_task", inputs: {"seconds" => 3},
                           mode: "fork").run

CLI, fork and wait_path (executed verbatim):

    scout workflow task WorkflowCoder run_task --workflow WFTestAI --task slow_task \
      --inputs '{"seconds":3}' --mode fork

    scout workflow task WorkflowCoder run_task --workflow WFTestAI --task slow_task \
      --inputs '{"seconds":2}' --mode wait_path

Observed responses (from the runs above, abbreviated):

    # fork -- returned in 0.7 s while the task sleeps 3 s
    {"mode":"fork","status":"start","job_path":".../WFTestAI/slow_task/Default_0ace1017a4617e070870efea9721bf48",
     "output":null,"submitted":true,"pid":21,"pid_alive":true,
     "messages":["Forked: job runs in a detached child process; poll with job_status, fetch with job_result."]}

    # wait_path -- blocked ~2 s, same path the preview predicted, no payload
    {"mode":"wait_path","status":"done","execution_time":2.014,"output":null,
     "output_type":"path_receipt","job_path":".../WFTestAI/slow_task/Default_2c00ffa16b5f007cb27754ca8b1a8f86"}

The control tasks never re-execute the job they address: reference resolution
goes through `Step.load` / `Workflow#load_job`, which produce a bare path-Step
with no task block, so nothing can run; status, result and files come straight
from the `.info` sidecar and the job file on disk. All of them are pure reads
except `job_stop`. Their wrapper caches are self-cleaned before each run, so
the same reference can be polled repeatedly and always returns the current
state of the underlying job.

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

- `workflow` (string, required unless `job` is given): Name of the workflow to
  load.
- `task` (string, required unless `job` is given): Name of the task to run.
- `inputs` (text, default {}): Hash of input name to value pairs, given as a
  JSON string. Keys may be strings or symbols; they are converted to
  symbols automatically.
- `clean` (boolean, default false): Clean this job's cached result before
  running.
- `recursive_clean` (boolean, default false): Clean all dependency caches
  before running.
- `stream` (boolean, default false): Pass `true` to `step.run` for streaming
  tasks.
- `mode` (select, default `wait_result`): how to submit the job. One of
  `wait_result` (block, run, return the result content -- the historical
  behavior), `wait_path` (block, run with `run(:no_load)`, return only the
  path, never the result payload), or `fork` (submit in a detached child
  process, return immediately with a path receipt). See the "Job submission
  and control" section above for the full picture and examples.
- `job` (string, optional): Reference to an existing job; when given, the
  recorded inputs are recovered from that job's `.info` file and replayed, so
  `workflow`, `task` and `inputs` do not need to be re-supplied. See the
  "Running by reference" paragraphs below.

The returned JSON contains:

- `status`: Execution status (done, error, aborted, waiting, etc.)
- `output`: The return value of the task (serialized, truncated if very long)
- `output_type`: Type hint for the output (string, array, hash, nil, etc.)
- `execution_time`: Wall-clock seconds for the execution phase
- `job_path`: Filesystem path to the job result
- `referenced_job`: Recovery echo, present only when `job` was given (see
  below)
- `files`: Array of file paths generated in the job's files_dir
- `warnings`: Non-fatal issues (unknown inputs, missing required inputs)
- `messages`: Log messages from step.info
- `exception_class`: Ruby exception class name if an error occurred
- `exception_message`: Human-readable exception message
- `backtrace_summary`: First 10-15 lines of the backtrace for debugging
- `dependencies`: List of dependency job names/paths
- `error_phase`: Where the error occurred (load_workflow, task_validation,
  input_validation, job_creation, job_reference, execution, or job_state for
  the result-of-unfinished report of `job_result`)

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

Running by reference

Instead of re-supplying `workflow`, `task` and `inputs`, pass the `job` input
with a reference to a job that was already run at least once. `run_task`
resolves the reference, recovers the inputs recorded in the referenced job's
`.info` (`info[:provided_inputs]`), merges any `inputs` JSON over them, and
replays them through the normal pipeline. When the inputs round-trip
faithfully the run lands on exactly the same job path; if that job is already
`done` the cached result is returned without recomputing.

Three reference forms are accepted, tried in this order:

- Full job path: the `job_path` value returned by `run_task`, `job_info` or
  `preview_job`. Absolute paths are used as-is; an existing relative path is
  accepted too. A trailing `.info` is tolerated. This is the most explicit
  form and the one to copy from a previous response.
- `short_path`: the three-segment `Workflow/task/name` identifier that
  `job_info` reports in its `short_path` field (and that `preview_job` also
  returns). Note on terminology: Scout has no `sort_path`; `short_path` is the
  same idea and is the accepted form here.
- `task/name` (two segments) together with the `workflow` option: resolved
  through `Workflow#load_job`. Useful when the workflow is already fixed and
  only the task and label need to be typed.

The examples below use a hypothetical `MyWorkflow/greet` job and are
illustrative: they cannot be executed verbatim because that workflow does not
exist in this checkout. The same three reference forms, executed against the
`WFTestAI` fixture, are verified in `tmp/cli_doc_verify.sh` (transcript in
`tmp/readme_examples_check.out`).

Example, run by full job path:

    scout workflow task WorkflowCoder run_task \
      --job /home/user/.scout/var/jobs/MyWorkflow/greet/Default_1a2b3c4d

Example, run by short_path:

    scout workflow task WorkflowCoder run_task \
      --job MyWorkflow/greet/Default_1a2b3c4d

Example, run by task/name plus workflow:

    scout workflow task WorkflowCoder run_task \
      --job greet/Default_1a2b3c4d --workflow MyWorkflow

Example, override one input on top of the recovered ones (overlay semantics:
entries in `inputs` win, untouched recovered entries are kept):

    scout workflow task WorkflowCoder run_task \
      --job MyWorkflow/greet/Default_1a2b3c4d \
      --inputs '{"name": "World"}'

Programmatic equivalent:

    WorkflowCoder.job(:run_task, nil,
      job: 'MyWorkflow/greet/Default_1a2b3c4d'
    ).run

Every run by reference echoes what happened in the `referenced_job` block:

    "referenced_job": {
      "reference": "MyWorkflow/greet/Default_1a2b3c4d",
      "kind": "short_path",           // path | short_path | task_name
      "resolved_path": "/home/user/.scout/var/jobs/MyWorkflow/greet/Default_1a2b3c4d",
      "short_path": "MyWorkflow/greet/Default_1a2b3c4d",
      "workflow": "MyWorkflow",
      "task": "greet",
      "recovered_inputs": { "name": "World" },
      "merged_inputs": false
    }

Inputs recorded in `.info` do not always round-trip perfectly: file and step
inputs serialize as paths, so rebuilding the job can land on a different job
path. That divergence is reported as a `warnings` entry, never as a failure,
and the remedy is the `save_inputs` / `load_inputs` bundle of the referenced
job (`scout workflow task ... --save_inputs dir` when producing it,
`--load_inputs dir` to reproduce it exactly).

A reference that cannot be resolved -- a typo, a job that was never run (no
`.info` exists), or `task/name` without the `workflow` option -- returns the
usual structured error JSON with `error_phase: "job_reference"` and a
`ParameterException` whose message lists every interpretation that was tried.
Reference resolution requires the job to have been run at least once, because
that is where the recovered inputs come from.


## job_status
Report the status of a job by reference

Reads the `.info` sidecar and the payload file and returns a normalized status
plus the raw engine status, the job pid and its liveness, the started/ended
timestamps, log messages and, when the job errored, the recorded exception.
The normalization is the scout-camp `serve_step` status model
(`lib/scout/sinatra/base.rb:81-100`) extended with pid liveness: terminal
states (`done`/`error`/`aborted`) pass through verbatim; any state whose pid
is alive is `running` (exactly the engine's own `running?` predicate,
scout-gear `info.rb:194-196`); a payload file with no terminal status counts
as `done`. `raw_status` always carries the sidecar value (`start` is what a
forked child writes while it runs).

Inputs:

- `job` (string, required): full job path, `Workflow/task/name`, or
  `task/name` plus the `workflow` option.
- `workflow` (string): only used to disambiguate `task/name` references.

Never triggers execution. Executed verbatim:

    scout workflow task WorkflowCoder job_status \
      --job /home/mvazque2/.scout/var/jobs/WFTestAI/slow_task/Default_0ace1017a4617e070870efea9721bf48

Observed (a running fork):

    {"status":"running","raw_status":"start","pid":21,"pid_alive":true,
     "job_reference":{"kind":"path",
       "resolved_path":"/home/mvazque2/.scout/var/jobs/WFTestAI/slow_task/Default_0ace1017a4617e070870efea9721bf48",
       "short_path":"WFTestAI/slow_task/Default_0ace1017a4617e070870efea9721bf48"}}

Ruby equivalent:

    WorkflowCoder.job(:job_status, nil,
      job: "WFTestAI/slow_task/Default_0ace1017a4617e070870efea9721bf48").run

## job_stop
Stop a running job by reference

Terminates the job through the engine's own abort path: `Step#abort` (TERM +
waitpid through `Misc.abort_child`), then a brief liveness check of
`info[:pid]`, escalating to `Process.kill("KILL", pid)` plus
`Misc.wait_child` only if the process survived the TERM, and finally a
`step.merge_info(:status => :aborted, :end => Time.now)` reconciliation.

CONVENTION: our stop always ends in `:aborted`. The engine itself only writes
`:aborted` from the streaming abort callback (scout-gear `step.rb:272`); a
TERM-killed forked child instead records `:error` with an `Aborted` exception
through the normal error path (`step.rb:248-261`), which is a recoverable
error and would make a deliberately stopped job look like a failed one. We
therefore normalize to `:aborted` so `aborted?` is truthfully true afterwards.
The merge uses `merge_info`, never `reset_info`/`update_info`: those replace
the whole info hash (`info.rb:34-42, 144-148`) and would drop the recorded
inputs and dependencies. scout-camp has no abort endpoint at all; this task is
engine-`Step#abort` based.

A job already `done`/`error`/`aborted` is reported as-is (`action: "none"`)
instead of being killed.

The `action` field distinguishes what happened: `aborted` when a live job
was stopped, and `none` for the two no-op cases -- an already terminal job
(`done`/`error`/`aborted`, reported with its status) and a job that was
never started (a `.info` sidecar with a non-terminal status but no pid,
left untouched). The two no-ops differ only in their `messages` entry.

Aborting is not permanent: rerunning the same task with the same inputs
after a stop starts a fresh run and reaches `done` normally (verified in
`tmp/readme_examples_check.out`: stop -> `action: aborted`, immediate rerun
-> `status: done`). The reconciliation only edits the `.info` of the stopped
job; it does not poison the task or the inputs.

Inputs: same `job` / `workflow` pair as `job_status`.

Executed verbatim (fork a 90 s job, then stop it; 8 s is too short to be
reliable, since each CLI invocation pays several seconds of startup and the
job may already be done -- the stop then correctly a no-op -- by the time
`job_stop` runs):

    scout workflow task WorkflowCoder run_task --workflow WFTestAI --task slow_task \
      --inputs '{"seconds":90}' --mode fork
    scout workflow task WorkflowCoder job_stop \
      --job <job_path from the fork receipt>

Observed: the first `job_status` after the fork reported `status: "running"`
with `pid_alive: true`; `job_stop` returned `status: "aborted"`,
`escalated: false`, `pid_alive: false`. A `job_status` immediately after the
stop may briefly still report the stale `start`/alive reading: the forked
child writes its own terminal state asynchronously while dying, and the two
writers race for the `.info` file. Within about half a second the state
settles and stays `status: "aborted"`, `raw_status: "aborted"`,
`pid_alive: false` (probe: `tmp/readme_abort_settle.out`).

Children caveat: TERM reaches the job pid only. Grandchildren started from
the task block with `step.cmd` / `CMD.cmd` are recorded in
`info[:children_pids]` and are NOT killed by `job_stop`; the framework has
no process-group kill. When such children are still alive after the stop,
the response carries `children_pids_alive` with their pids plus a warning,
so they can be killed separately if they must not outlive the job. (Probed
with a task that spawns a `sleep` through `step.cmd`; the response reported
the still-alive child -- `tmp/verify_gap_check.out`, gap 5.)

Ruby equivalent:

    WorkflowCoder.job(:job_stop, nil,
      job: "/home/mvazque2/.scout/var/jobs/WFTestAI/slow_task/Default_ffa5c6f46131596b3eabca031870b351").run

## job_result
Load the result payload of a finished job by reference

Reads the job's stored payload from its job file (no task block involved, so
nothing can re-execute). A `done` job returns its content in `output` (truncated
to 5000 bytes with a warning when larger); an `error` job returns its recorded
exception; an `aborted` job reports that; a job still running or waiting
reports `output_type: "in_progress"` and `error_phase: "job_state"`
with the current status instead of blocking (a state report, not a failure).

Inputs: same `job` / `workflow` pair as `job_status` (`job` accepts the full
job path, `Workflow/task/name`, or `task/name` plus the `workflow` option).

Executed verbatim:

    scout workflow task WorkflowCoder job_result \
      --job /home/mvazque2/.scout/var/jobs/WFTestAI/slow_task/Default_0ace1017a4617e070870efea9721bf48

Observed:

    {"status":"done","output":"slow_task done after 3.0s (requested 3s)",
     "job_reference":{"kind":"path", ...}}

Ruby equivalent:

    WorkflowCoder.job(:job_result, nil,
      job: "WFTestAI/slow_task/Default_0ace1017a4617e070870efea9721bf48").run

## job_files
List (or read) the files produced by a job

Lists every file in the job's `files_dir` with path, size and mtime. With the
optional `file` input, reads ONE file instead: the payload is returned bounded
by `max_bytes` (default 5000) and binary files are reported as binary rather
than dumped. Requesting a file that is not in this job's `files_dir` returns
`error_phase: "input_validation"`.

Inputs: `job` / `workflow` as above, plus `file` (string, optional) and
`max_bytes` (integer, default 5000).

Executed verbatim (a task that wrote two files into its files_dir):

    scout workflow task WorkflowCoder job_files \
      --job /home/mvazque2/.scout/var/jobs/WFTestAI/files_task/Default

Observed:

    {"status":"done","files":[
      {"path":".../WFTestAI/files_task/Default.files/binary.bin",
       "name":"binary.bin","size":64,"mtime":"2026-09-04 09:28:40 +0200"},
      {"path":".../WFTestAI/files_task/Default.files/report.txt",
       "name":"report.txt","size":2400,"mtime":"2026-09-04 09:28:40 +0200"}]}

Reading one file, bounded (Ruby equivalent):

    WorkflowCoder.job(:job_files, nil,
      job: "WFTestAI/files_task/Default",
      file: "report.txt", max_bytes: 40).run

Observed:

    {"status":"done","file":"report.txt",
     "content":"line1\nline2\nline1\nline2\nline1\nline2\nline1...(truncated)",
     "warnings":["File 'report.txt' (2400 bytes) truncated to 40 bytes."]}

A binary file is reported, not dumped (`"binary": true` with its size, the
`content` key stays null); a name not present in this job's files_dir returns
`error_phase: "input_validation"` with a `ParameterException` that lists the
available files. Full transcript: `tmp/probe_files.out`.

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
- `short_path`: Compact `Workflow/task/name` identifier of the job; this is
  the value to pass as the `job` input of `run_task` when running by
  reference
- `files`: Files in the job's files_dir (if any)

Example usage:

    job_info(
      workflow="ComputerUse",
      task="current_time",
      inputs={}
    )

## preview_job
Preview the job path a task run would get, without running it

This is the dry-run companion of `run_task`: it goes through the exact same
phases (load workflow, task validation, input validation, job creation) with
the same warnings and the same `error_phase` taxonomy, but stops after the
job is created. The job is NOT executed: no `run`/`exec`/`persist` is issued,
no `.info` file is written, and no cache entry is touched, so previewing has
no effect on the job's state or on a later run.

Inputs:

- `workflow` (string, required): Name of the workflow to load.
- `task` (string, required): Name of the task to preview.
- `inputs` (text, default {}): Hash of input name to value pairs, given as a
  JSON string.

The returned JSON contains:

- `job_path`: Full filesystem path the job result would occupy
- `short_path`: Compact `Workflow/task/name` identifier of the job
- `name` and `clean_name`: The job label and its label without the hash
  suffix (see the job identity notes in the introduction)
- `files_dir`: Directory where the job's produced files would live
- `non_default_inputs`: The inputs that made the job label non-default
- `dependencies`: short_paths of the jobs this run would depend on
- `info_exists` and `result_exists`: Whether this exact job was already run
  before
- `status`: Read from the existing `.info` when present, `not_run` otherwise
- `executed`: Always false; a marker that the preview never ran anything
- `warnings`, `messages`, `exception_class`, `exception_message`,
  `backtrace_summary`, `error_phase`: same diagnostics contract as `run_task`

Use it to check where a run will land before committing to it (for instance
before a long computation), to see whether an equivalent job already exists
and in what state, or to validate inputs without any side effect: input
mistakes surface here with the same `warnings` and `error_phase` they would
produce in `run_task`.

Example usage:

    preview_job(
      workflow="ComputerUse",
      task="read",
      inputs={"path": "workflow.rb"}
    )

Same call on the command line:

    scout workflow task WorkflowCoder preview_job \
      --workflow ComputerUse --task read \
      --inputs '{"path": "workflow.rb"}'

Example response (abbreviated):

    {
      "status": "not_run",
      "executed": false,
      "job_path": "/home/user/.scout/var/jobs/ComputerUse/read/Default_5f4e3d2c",
      "short_path": "ComputerUse/read/Default_5f4e3d2c",
      "name": "Default_5f4e3d2c",
      "clean_name": "Default",
      "non_default_inputs": ["path"],
      "info_exists": false,
      "result_exists": false
    }

Note that `preview_job` addresses a job by its (would-be) inputs. To inspect
or re-run a job you already have a reference to, use `job_info` /
`run_task --job` instead; for the four-way submission picture (wait_result /
wait_path / fork / preview) see "Job submission and control" above.
