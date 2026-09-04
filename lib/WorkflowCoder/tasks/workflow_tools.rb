module WorkflowCoder
  # Submission modes accepted by run_task's mode input. preview_job is the
  # fourth submission point and is not a mode value: it submits nothing.
  SUBMISSION_MODES = %w(wait_result wait_path fork).freeze unless defined?(SUBMISSION_MODES)

  helper :require_workflow do |workflow|
    Workflow.require_workflow workflow.to_s
  end

  # Shared job-resolution plumbing used by run_task and preview_job.
  #
  # Phase 1 loads the workflow, phase 2 validates that the task exists,
  # phase 3 collects input warnings (unknown inputs, missing required
  # inputs) and converts keys to symbols, and phase 4 creates the job
  # WITHOUT running it (Workflow#job only builds the Step; execution
  # starts at Step#run).
  #
  # On failure it fills `result` with the same error diagnostics run_task
  # has always produced (status/error_phase/exception_*/backtrace_summary)
  # and returns nil. On success it sets result[:job_path] and returns the
  # Step. It never raises to the caller.
  def self.resolve_job(workflow, task, inputs, result)
    inputs = JSON.parse inputs if String === inputs

    # Phase 1: Load workflow
    wf = nil
    begin
      wf = Workflow.require_workflow workflow.to_s
    rescue Exception => e
      result[:status] = "error"
      result[:error_phase] = "load_workflow"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
      return nil
    end

    # Phase 2: Validate task exists
    tname = task.to_sym
    unless wf.tasks.include?(tname)
      result[:status] = "error"
      result[:error_phase] = "task_validation"
      result[:exception_class] = "ParameterException"
      result[:exception_message] = "Task '#{task}' not found in workflow '#{workflow}'. Available tasks: #{wf.tasks.keys.sort_by(&:to_s).join(', ')}"
      return nil
    end

    t = wf.tasks[tname]

    # Phase 3: Input validation (best-effort, non-blocking)
    provided_keys = inputs ? inputs.keys.map(&:to_s) : []
    task_input_names = (t.recursive_inputs || t.inputs || []).map{|i| i[0].to_s }

    # Warn about unknown inputs (typos, wrong names)
    if provided_keys.any?
      known_set = task_input_names.to_set
      provided_keys.each do |k|
        unless known_set.include?(k)
          result[:warnings] << "Input '#{k}' is not recognized by task '#{task}'. Known inputs: #{task_input_names.join(', ')}"
        end
      end
    end

    # Check for required inputs
    (t.recursive_inputs || t.inputs || []).each do |i|
      iname, itype, idesc, idefault, iopts = i
      if iopts && iopts[:required] && !provided_keys.include?(iname.to_s)
        result[:warnings] << "Required input '#{iname}' was not provided."
      end
    end

    # Convert string keys to symbols for Scout compatibility
    sym_inputs = {}
    if inputs
      inputs.each do |k, v|
        sym_inputs[k.to_sym] = v
      end
    end

    # Phase 4: Create job (builds the Step, does not run it)
    #
    # ScoutCoder: the job label Scout derives inside Workflow#job is 'Default'
    # when only default inputs are used, and 'Default_<md5>' otherwise; the md5
    # covers the non-default provided inputs and the resolved dependencies
    # (scout-gear task.rb:108-116), so identical inputs land on the identical
    # job path in any process.
    step = nil
    begin
      step = wf.job(tname, nil, sym_inputs)
    rescue ParameterException => e
      result[:status] = "error"
      result[:error_phase] = "input_validation"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(5) : []
      return nil
    rescue Exception => e
      result[:status] = "error"
      result[:error_phase] = "job_creation"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
      return nil
    end

    result[:job_path] = step.path.to_s if step.respond_to?(:path)

    step
  end

  # Resolve a job reference into a previously-run Step.
  #
  # Accepted forms, tried in this order:
  # - :path       -- an existing filesystem path (the job_path returned by
  #                  run_task / job_info / preview_job); resolved with
  #                  Step.load, which also prefixes var/jobs and relocates.
  #                  A trailing .info is tolerated and stripped.
  # - :short_path -- a 3-segment 'Workflow/task/name' string (Step#short_path,
  #                  the identifier job_info reports; Scout has no
  #                  'sort_path', short_path is the same idea).
  # - :task_name  -- a 2-segment 'task/name' string; requires the workflow
  #                  option and is resolved with Workflow#load_job.
  #
  # A candidate only counts when its .info file exists (the job was run at
  # least once), because inputs are recovered from that .info. Step.load
  # itself never fails -- it constructs a Step even for bogus paths -- so
  # existence is checked here instead.
  #
  # ScoutCoder: Step#short_path is 'Workflow/task/name' -- a relative,
  # pathmap-resolved identifier (Var.find_path... under var/jobs), and it is
  # what job_info reports as the canonical short job reference. Note Scout has
  # no 'sort_path' concept; short_path is the accepted form of that idea.
  #
  # ScoutCoder: the .info file is written only when the job starts running
  # (scout-gear step.rb:210-216), so requiring it here doubles as a
  # 'was actually run' test; input recovery reads info[:provided_inputs],
  # which records exactly the inputs the caller supplied (non-default and
  # default alike).
  #
  # On success sets result[:referenced_job] (reference, kind, resolved_path,
  # short_path) and returns the loaded Step. On failure fills `result` with
  # error_phase 'job_reference' and returns nil. It never raises.
  def self.load_job_reference(reference, workflow, result)
    ref = reference.to_s.strip.sub(/\.info$/, '')

    fail_reference = lambda do |message|
      result[:status] = "error"
      result[:error_phase] = "job_reference"
      result[:exception_class] = "ParameterException"
      result[:exception_message] = message
    end

    return fail_reference.call("Job reference is empty.") && nil if ref.empty?

    segments = ref.split("/").reject{|s| s.empty? }

    # Run each candidate resolution, capturing exceptions as values so one
    # bad interpretation does not abort the others.
    safe = lambda do |&block|
      begin
        block.call
      rescue Exception => e
        e
      end
    end

    attempts = []
    if ref.start_with?("/") || Open.exists?(ref) || Open.exists?(ref + ".info")
      attempts << [:path, ref, safe.call{ Step.load(ref) }]
    end
    if segments.length == 3
      attempts << [:short_path, segments * "/", safe.call{ Step.load(segments * "/") }]
    end
    if segments.length == 2 && !workflow.to_s.strip.empty?
      label = [workflow.to_s, segments * "/"] * "/"
      attempts << [:task_name, label, safe.call{
        Workflow.require_workflow(workflow.to_s).load_job(segments[0], segments[1])
      }]
    end

    tried = []
    attempts.each do |kind, label, outcome|
      unless Step === outcome
        tried << "#{label}: #{outcome.class}: #{outcome.message}"
        next
      end
      info_file = begin
                    outcome.respond_to?(:info_file) ? outcome.info_file : nil
                  rescue Exception
                    nil
                  end
      if info_file && Open.exists?(info_file)
        result[:referenced_job] = {
          reference: reference.to_s,
          kind: kind.to_s,
          resolved_path: outcome.path.to_s,
          short_path: outcome.short_path.to_s,
        }
        return outcome
      end
      tried << "#{label}: no .info at #{info_file || '?'} (job was never run or does not exist)"
    end

    detail = tried.any? ? tried.join(" ; ") :
      "no interpretation matched (expected an existing job path, 'Workflow/task/name', or 'task/name' together with the workflow option)"
    fail_reference.call("Could not resolve job reference '#{reference}'. Tried: #{detail}.")
    nil
  end

  # JSON-safe rendering of a recovered input value: scalars pass through,
  # arrays and hashes recurse, anything else (Path, Step, ...) is to_s'd.
  def self.json_safe_value(value)
    case value
    when String, Integer, Float, TrueClass, FalseClass, NilClass
      value
    when Array
      value.collect{|v| WorkflowCoder.json_safe_value(v) }
    when Hash
      new = {}
      value.each{|k, v| new[k.to_s] = WorkflowCoder.json_safe_value(v) }
      new
    else
      value.to_s
    end
  end

  # JSON-safe rendering of a whole inputs hash (string keys).
  def self.json_safe_inputs(inputs)
    return {} if inputs.nil?
    new = {}
    inputs.each{|k, v| new[k.to_s] = WorkflowCoder.json_safe_value(v) }
    new
  end

  helper :require_workflow do |workflow|
    Workflow.require_workflow workflow.to_s
  end

  input :workflow, :string, "Name of the workflow to inspect"
  task :list_tasks => :json do |workflow|
    raise ParameterException, "workflow is required" if workflow.nil? || workflow.to_s.strip.empty?

    wf = require_workflow workflow

    wf.tasks.sort_by{|name, _| name.to_s}.map do |name, task|
      inputs = (task.inputs || []).map do |i|
        iname, itype, idesc, idefault, iopts = i
        {
          name: iname,
          type: itype.to_s,
          description: idesc,
          default: idefault.nil? ? nil : idefault.to_s,
          required: iopts && iopts[:required] ? true : false,
        }
      end

      deps = []
      begin
        deps = (task.deps || []).map{|d| d.is_a?(Array) ? d.map{|e| e.is_a?(Symbol) ? e.to_s : e.to_s } : d.to_s }
      rescue
        deps = []
      end

      {
        name: name.to_s,
        description: task.description.to_s,
        type: task.type.to_s,
        inputs: inputs,
        dependencies: deps,
      }
    end
  end

  input :workflow, :string, "Name of the workflow"
  input :task, :string, "Name of the task to inspect"
  task :task_inputs => :json do |workflow, task|
    raise ParameterException, "workflow is required" if workflow.nil? || workflow.to_s.strip.empty?
    raise ParameterException, "task is required" if task.nil? || task.to_s.strip.empty?

    wf = require_workflow workflow
    tname = task.to_sym

    raise ParameterException, "Task '#{task}' not found in workflow '#{workflow}'. Available: #{wf.tasks.keys.sort_by(&:to_s).join(', ')}" unless wf.tasks.include?(tname)

    t = wf.tasks[tname]

    # recursive_inputs includes inputs propagated from dependencies
    recursive_inputs = []
    begin
      recursive_inputs = (t.recursive_inputs || []).map do |i|
        iname, itype, idesc, idefault, iopts = i
        {
          name: iname,
          type: itype.to_s,
          description: idesc,
          default: idefault.nil? ? nil : idefault.to_s,
          required: iopts && iopts[:required] ? true : false,
        }
      end
    rescue => e
      recursive_inputs = [{ error: "Could not retrieve recursive_inputs: #{e.message}" }]
    end

    # Direct inputs (declared on this task only)
    direct_inputs = (t.inputs || []).map do |i|
      iname, itype, idesc, idefault, iopts = i
      {
        name: iname,
        type: itype.to_s,
        description: idesc,
        default: idefault.nil? ? nil : idefault.to_s,
        required: iopts && iopts[:required] ? true : false,
      }
    end

    {
      workflow: workflow.to_s,
      task: task.to_s,
      description: t.description.to_s,
      result_type: t.type.to_s,
      direct_inputs: direct_inputs,
      recursive_inputs: recursive_inputs,
    }
  end

  input :workflow, :string, "Name of the workflow to load and execute (optional when job is given)"
  input :task, :string, "Name of the task to run (optional when job is given)"
  input :inputs, :text, "Hash of input name to value pairs in JSON", {}
  input :clean, :boolean, "Clean the job cache before running", false
  input :recursive_clean, :boolean, "Clean all dependency caches before running", false
  input :stream, :boolean, "Stream output for streaming tasks", false
  input :mode, :select, "Submission mode: wait_result (block and return the result), wait_path (block and return only the job path), fork (background submission, return a receipt immediately)", "wait_result", select_options: SUBMISSION_MODES
  input :job, :string, "Reference to an existing job: full job path, short_path 'Workflow/task/name', or 'task/name' plus the workflow option", nil, nofile: true
  task :run_task => :json do |workflow, task, inputs, clean, recursive_clean, stream, mode, job|

    inputs = JSON.parse inputs if String === inputs

    result = {
      workflow: workflow.to_s,
      task: task.to_s,
      mode: (mode || "wait_result").to_s,
      status: nil,
      execution_time: nil,
      output: nil,
      output_type: nil,
      job_path: nil,
      referenced_job: nil,
      files: [],
      warnings: [],
      messages: [],
      exception_class: nil,
      exception_message: nil,
      backtrace_summary: [],
      dependencies: [],
      error_phase: nil,
    }

    # Validate the mode early: an invalid value is an input problem, and
    # reporting it before any resolution or execution keeps the taxonomy
    # consistent with the other input errors.
    if mode && !mode.to_s.strip.empty? && !SUBMISSION_MODES.include?(mode.to_s)
      result[:mode] = mode.to_s
      result[:status] = "error"
      result[:error_phase] = "input_validation"
      result[:exception_class] = "ParameterException"
      result[:exception_message] = "Invalid mode '#{mode}'. Valid modes: #{SUBMISSION_MODES.join(', ')} (preview_job is the fourth submission point but is a separate task, not a mode)."
      next result
    end

    # Phase 1: Load workflow
    wf = nil
    begin
      wf = require_workflow workflow
    rescue Exception => e
      result[:status] = "error"
      result[:error_phase] = "load_workflow"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
      next result
    end

    # Phase 2: Validate task exists
    tname = task.to_sym
    unless wf.tasks.include?(tname)
      result[:status] = "error"
      result[:error_phase] = "task_validation"
      result[:exception_class] = "ParameterException"
      result[:exception_message] = "Task '#{task}' not found in workflow '#{workflow}'. Available tasks: #{wf.tasks.keys.sort_by(&:to_s).join(', ')}"
      next result
    end

    t = wf.tasks[tname]

    # Phase 3: Input validation (best-effort, non-blocking)
    provided_keys = inputs ? inputs.keys.map(&:to_s) : []
    task_input_names = (t.recursive_inputs || t.inputs || []).map{|i| i[0].to_s }

    # Warn about unknown inputs (typos, wrong names)
    if provided_keys.any?
      known_set = task_input_names.to_set
      provided_keys.each do |k|
        unless known_set.include?(k)
          result[:warnings] << "Input '#{k}' is not recognized by task '#{task}'. Known inputs: #{task_input_names.join(', ')}"
        end
      end
    end

    # Check for required inputs
    (t.recursive_inputs || t.inputs || []).each do |i|
      iname, itype, idesc, idefault, iopts = i
      if iopts && iopts[:required] && !provided_keys.include?(iname.to_s)
        result[:warnings] << "Required input '#{iname}' was not provided."
      end
    end

    # Convert string keys to symbols for Scout compatibility
    sym_inputs = {}
    if inputs
      inputs.each do |k, v|
        sym_inputs[k.to_sym] = v
      end
    end

    # Phase 4: Create job
    step = nil
    begin
      step = wf.job(tname, nil, sym_inputs)
    rescue ParameterException => e
      result[:status] = "error"
      result[:error_phase] = "input_validation"
      result[:exception_class] = "ParameterException"
      result[:exception_message] = "Invalid mode '#{mode}'. Valid modes: #{SUBMISSION_MODES.join(', ')} (preview_job is the fourth submission point but is a separate task, not a mode)."
      next result
    end

    # Phase 0: run by reference. Resolve the reference, recover the inputs
    # recorded in the referenced job's .info, and let the normal phases
    # below replay them.
    if job && !job.to_s.strip.empty?
      loaded = WorkflowCoder.load_job_reference(job, workflow, result)
      next result if loaded.nil?

      begin
        info = loaded.info
        provided = info[:provided_inputs]
        non_default = info[:non_default_inputs] || []

        if provided.nil? && non_default.any?
          result[:status] = "error"
          result[:error_phase] = "job_reference"
          result[:exception_class] = "ParameterException"
          result[:exception_message] = "Referenced job records non-default inputs but no provided_inputs could be recovered from #{loaded.info_file}"
          next result
        end

        recovered = {}
        (provided || {}).each{|k, v| recovered[k.to_s] = v }

        # ScoutCoder: merging is overlay semantics -- entries in the `inputs`
        # JSON win over the recovered ones, and untouched recovered entries are
        # kept. File inputs recovered from .info serialize as paths (not as
        # content digests), so a rebuild can land on a different job label when
        # the file changed or the input format differs; that divergence is
        # reported as a warning below, not an error.
        merged = false
        if String === inputs && !inputs.strip.empty?
          begin
            extra = JSON.parse inputs
            merged = true
            (extra || {}).each{|k, v| recovered[k.to_s] = v }
          rescue JSON::ParserError
            result[:warnings] << "Could not parse inputs JSON; ignoring it and using only the inputs recovered from the referenced job."
          end
        elsif Hash === inputs && inputs.any?
          merged = true
          inputs.each{|k, v| recovered[k.to_s] = v }
        end

        workflow = info[:workflow].to_s
        task = info[:task_name].to_s
        result[:workflow] = workflow
        result[:task] = task

        ref = result[:referenced_job]
        ref[:workflow] = workflow
        ref[:task] = task
        ref[:recovered_inputs] = WorkflowCoder.json_safe_inputs(recovered)
        ref[:merged_inputs] = merged

        inputs = recovered
      rescue Exception => e
        result[:status] = "error"
        result[:error_phase] = "job_reference"
        result[:exception_class] = e.class.name
        result[:exception_message] = e.message
        result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
        next result
      end
    end

    # Phases 1-4: load workflow, validate task, validate inputs, create job
    step = WorkflowCoder.resolve_job(workflow, task, inputs, result)
    next result if step.nil?

    # Fidelity guard for run-by-reference: warn (never fail) when the
    # rebuilt job lands somewhere else than the referenced job.
    if result[:referenced_job] && result[:job_path] && result[:job_path] != result[:referenced_job][:resolved_path]
      result[:warnings] << "Rebuilt job path (#{result[:job_path]}) differs from the referenced job (#{result[:referenced_job][:resolved_path]}). Inputs recorded in .info do not always round-trip: file and step inputs serialize as paths and can diverge through input formatting. Use the save_inputs / load_inputs bundle of the referenced job when exact fidelity is required."
    end

    # Phase 5: Optional clean
    if recursive_clean
      begin
        step.recursive_clean if step.respond_to?(:recursive_clean)
        result[:messages] << "Recursively cleaned job and dependencies."
      rescue Exception => e
        result[:warnings] << "recursive_clean failed: #{e.message}"
      end
    elsif clean
      begin
        step.clean if step.respond_to?(:clean)
        result[:messages] << "Cleaned job cache."
      rescue Exception => e
        result[:warnings] << "clean failed: #{e.message}"
      end
    end

    # Phase 6: Execute. wait_result is exactly the historical behavior;
    # wait_path and fork dispatch to their helpers below. The mode was
    # already validated during input validation above.
    chosen_mode = (mode || "wait_result").to_s
    if chosen_mode == "fork"
      next WorkflowCoder.fork_submit(step, result)
    elsif chosen_mode == "wait_path"
      next WorkflowCoder.wait_path_run(step, result)
    end

    output_value = nil
    start_time = Time.now
    begin
      output_value = step.run(stream)
      result[:execution_time] = (Time.now - start_time).round(3)
    rescue Exception => e
      result[:execution_time] = (Time.now - start_time).round(3)
      result[:status] = "error"
      result[:error_phase] = "execution"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(15) : []

      # Still try to gather diagnostics from step.info
      begin
        info = step.info
        result[:messages] = (info[:messages] || []).map(&:to_s) if info[:messages]
        result[:status] = info[:status].to_s if info[:status]
        if info[:dependencies]
          result[:dependencies] = info[:dependencies].map{|d| d.is_a?(Hash) ? (d[:name] || d[:path] || d.to_s) : d.to_s }
        end
      rescue
      end
      next result
    end

    # Phase 7: Collect structured results
    begin
      info = step.info

      result[:status] = info[:status] ? info[:status].to_s : (step.done? ? "done" : "unknown")

      # Collect messages/logs
      if info[:messages]
        result[:messages] = (info[:messages] || []).map(&:to_s)
      end

      # Collect dependency info
      if info[:dependencies]
        result[:dependencies] = info[:dependencies].map do |d|
          d.is_a?(Hash) ? (d[:name] || d[:path] || d.to_s) : d.to_s
        end
      end

      # Collect exception info if the step errored
      if info[:exception]
        exc_info = info[:exception]
        if exc_info.is_a?(Hash)
          result[:exception_class] = exc_info[:class] || exc_info[:name] || exc_info.class.name
          result[:exception_message] = exc_info[:message] || exc_info.to_s
        else
          result[:exception_message] = exc_info.to_s
        end
      end
    rescue => e
      result[:warnings] << "Could not read step.info: #{e.message}"
    end

    # Serialize output value
    begin
      if output_value.nil?
        result[:output] = nil
        result[:output_type] = "nil"
      elsif output_value.is_a?(String)
        result[:output] = output_value.length > 5000 ? output_value[0..5000] + "...(truncated)" : output_value
        result[:output_type] = "string"
      elsif output_value.is_a?(Array)
        result[:output] = output_value
        result[:output_type] = "array"
      elsif output_value.is_a?(Hash)
        result[:output] = output_value
        result[:output_type] = "hash"
      elsif [TrueClass, FalseClass, Integer, Float].any?{|c| output_value.is_a?(c) }
        result[:output] = output_value
        result[:output_type] = output_value.class.to_s
      elsif output_value.respond_to?(:read) && output_value.respond_to?(:path)
        # IO / file-like object
        path = output_value.respond_to?(:path) ? output_value.path : nil
        result[:output] = path ? "file:#{path}" : "io_object"
        result[:output_type] = "io"
      else
        str_val = output_value.to_s
        result[:output] = str_val.length > 5000 ? str_val[0..5000] + "...(truncated)" : str_val
        result[:output_type] = output_value.class.to_s
      end
    rescue => e
      result[:output] = "Could not serialize output: #{e.message}"
      result[:output_type] = "serialization_error"
    end

    # Collect generated files
    begin
      if step.respond_to?(:files_dir) && step.files_dir && File.exist?(step.files_dir)
        result[:files] = Dir.glob(File.join(step.files_dir, "**/*")).select{|f| File.file?(f) }
      end
    rescue => e
      result[:warnings] << "Could not list files_dir: #{e.message}"
    end

    # Ensure status is set
    result[:status] ||= "done"

    result
  end

  input :workflow, :string, "Name of the workflow"
  input :task, :string, "Name of the task"
  input :inputs, :text, "Hash of input name to value pairs in JSON", {}
  input :recursive, :boolean, "Clean all dependency results recursively", false
  task :clean_job => :json do |workflow, task, inputs, recursive|
    raise ParameterException, "workflow is required" if workflow.nil? || workflow.to_s.strip.empty?
    raise ParameterException, "task is required" if task.nil? || task.to_s.strip.empty?

    inputs = JSON.parse inputs if String === inputs

    wf = require_workflow workflow
    tname = task.to_sym

    raise ParameterException, "Task '#{task}' not found in workflow '#{workflow}'" unless wf.tasks.include?(tname)

    sym_inputs = {}
    inputs.each{|k, v| sym_inputs[k.to_sym] = v } if inputs

    step = wf.job(tname, nil, sym_inputs)
    job_path = step.path.to_s if step.respond_to?(:path)

    cleaned = []
    if recursive && step.respond_to?(:recursive_clean)
      step.recursive_clean
      cleaned << "#{workflow}/#{task}"
    elsif step.respond_to?(:clean)
      step.clean
      cleaned << "#{workflow}/#{task}"
    end

    {
      status: "done",
      workflow: workflow.to_s,
      task: task.to_s,
      job_path: job_path,
      cleaned: cleaned,
      recursive: recursive,
    }
  end

  input :workflow, :string, "Name of the workflow"
  input :task, :string, "Name of the task"
  input :inputs, :text, "Hash of input name to value pairs in JSON", {}, nofile: true
  task :job_info => :json do |workflow, task, inputs|
    raise ParameterException, "workflow is required" if workflow.nil? || workflow.to_s.strip.empty?
    raise ParameterException, "task is required" if task.nil? || task.to_s.strip.empty?

    inputs = JSON.parse inputs if String === inputs

    wf = require_workflow workflow
    tname = task.to_sym

    raise ParameterException, "Task '#{task}' not found in workflow '#{workflow}'" unless wf.tasks.include?(tname)

    sym_inputs = {}
    inputs.each{|k, v| sym_inputs[k.to_sym] = v } if inputs

    step = wf.job(tname, nil, sym_inputs)

    result = {
      workflow: workflow.to_s,
      task: task.to_s,
      job_path: step.respond_to?(:path) ? step.path.to_s : nil,
      short_path: step.respond_to?(:short_path) ? step.short_path.to_s : nil,
      status: nil,
      messages: [],
      dependencies: [],
      exception: nil,
      time_started: nil,
      time_done: nil,
    }

    begin
      info = step.info
      result[:status] = info[:status] ? info[:status].to_s : "unknown"
      result[:messages] = (info[:messages] || []).map(&:to_s)
      result[:time_started] = info[:started] ? info[:started].to_s : nil
      result[:time_done] = info[:done] ? info[:done].to_s : nil

      if info[:dependencies]
        result[:dependencies] = info[:dependencies].map do |d|
          d.is_a?(Hash) ? (d[:name] || d[:path] || d.to_s) : d.to_s
        end
      end

      if info[:exception]
        exc = info[:exception]
        result[:exception] = exc.is_a?(Hash) ? {
          class: exc[:class] || exc[:name],
          message: exc[:message] || exc.to_s,
        } : { message: exc.to_s }
      end
    rescue => e
      result[:status] = "error"
      result[:exception] = { class: e.class.name, message: e.message }
    end

    # Check for files
    begin
      if step.respond_to?(:files_dir) && step.files_dir && File.exist?(step.files_dir)
        files = Dir.glob(File.join(step.files_dir, "**/*")).select{|f| File.file?(f) }
        result[:files] = files
      end
    rescue
    end

    result
  end

  input :workflow, :string, "Name of the workflow to load"
  input :task, :string, "Name of the task to preview"
  input :inputs, :text, "Hash of input name to value pairs in JSON", {}, nofile: true
  task :preview_job => :json do |workflow, task, inputs|
    result = {
      workflow: workflow.to_s,
      task: task.to_s,
      status: nil,
      executed: false,
      job_path: nil,
      short_path: nil,
      name: nil,
      clean_name: nil,
      files_dir: nil,
      non_default_inputs: [],
      dependencies: [],
      info_exists: nil,
      result_exists: nil,
      warnings: [],
      messages: [],
      exception_class: nil,
      exception_message: nil,
      backtrace_summary: [],
      error_phase: nil,
    }

    # Phases 1-4: load workflow, validate task, validate inputs, create job
    # (creates the Step only; nothing is executed)
    step = WorkflowCoder.resolve_job(workflow, task, inputs, result)
    next result if step.nil?

    # Phase 5: collect preview information (read-only)
    #
    # ScoutCoder: constructing a Step with Workflow#job (resolve_job above) is
    # side-effect free -- no .info is written and no result is produced -- so
    # this whole preview reads job identity and existing state without
    # disturbing a later run. Note file-valued inputs are digested by CONTENT
    # inside the label computation, so the previewed job_path moves when an
    # input file's content changes even if its path string stays the same.
    begin
      result[:job_path] = step.path.to_s if step.respond_to?(:path)
      result[:short_path] = step.short_path.to_s
      result[:name] = step.name.to_s
      result[:clean_name] = step.clean_name.to_s
      result[:files_dir] = step.files_dir.to_s if step.respond_to?(:files_dir)

      non_default = step.non_default_inputs if step.respond_to?(:non_default_inputs)
      result[:non_default_inputs] = (non_default || []).collect{|i| i.to_s }

      deps = step.dependencies if step.respond_to?(:dependencies)
      result[:dependencies] = (deps || []).collect{|d| d.respond_to?(:short_path) ? d.short_path.to_s : d.to_s }

      info_file = step.info_file if step.respond_to?(:info_file)
      result[:info_exists] = info_file ? Open.exists?(info_file) : false
      result[:result_exists] = step.respond_to?(:done?) ? step.done? : Open.exists?(step.path)

      if result[:info_exists]
        info = step.info
        result[:status] = info[:status] ? info[:status].to_s : "unknown"
        result[:messages] = (info[:messages] || []).map(&:to_s) if info[:messages]
      else
        result[:status] = "not_run"
      end

      result[:messages] << "Preview only: job was not executed, no .info written, no cache touched."
    rescue Exception => e
      result[:status] = "error"
      result[:error_phase] = "job_creation"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
    end

    result
  end

  # ---- Submission mode helpers (run_task) ----

  # wait_path: blocking run WITHOUT loading the result into memory.
  #
  # ScoutCoder: `run(:no_load)` -- NOT `run(true)` -- is the "wait until
  # done but never materialize the result" form: run(true) maps no_load to
  # :stream and returns an open IO (scout-gear step.rb:171-179, 240-245),
  # while run(:no_load) consumes all streams and sets @result = nil
  # (240-242); produce without fork is exactly run(:no_load) (397-406).
  def self.wait_path_run(step, result)
    start_time = Time.now
    begin
      step.run(:no_load)
      result[:execution_time] = (Time.now - start_time).round(3)
    rescue Exception => e
      result[:execution_time] = (Time.now - start_time).round(3)
      result[:status] = "error"
      result[:error_phase] = "execution"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(15) : []
      WorkflowCoder.fill_info_diagnostics(step, result)
      return result
    end

    begin
      info = step.info
      result[:status] = info[:status] ? info[:status].to_s : (step.done? ? "done" : "unknown")
      result[:output_type] = "path_receipt"
      result[:messages] = (info[:messages] || []).map(&:to_s) if info[:messages]
      result[:dependencies] = WorkflowCoder.info_dependencies(info) if info[:dependencies]
      WorkflowCoder.attach_info_exception(info, result)
    rescue Exception => e
      result[:warnings] << "Could not read step.info: #{e.message}"
    end

    # Identity echo: a wait_path receipt carries job_path, short_path and
    # files_dir alongside the status, never the result content.
    WorkflowCoder.attach_job_identity(step, result)

    # Collect generated files (same convention as wait_result)
    begin
      if step.respond_to?(:files_dir) && File.exist?(step.files_dir)
        result[:files] = Dir.glob(File.join(step.files_dir, "**/*")).select{|f| File.file?(f) }
      end
    rescue Exception => e
      result[:warnings] << "Could not list files_dir: #{e.message}"
    end

    result
  end

  # fork: background submission mirroring scout-camp's asynchronous
  # initiate_step (lib/scout/sinatra/base.rb:68-76 in ~/git/scout-camp):
  # Step#fork unless started, then Open.wait_for(step.path, timeout: 0.5)
  # to absorb the fork -> first .info write race, then return immediately.
  #
  # ScoutCoder: Step#fork (scout-gear step.rb:291-310) is the engine-native
  # background mechanism: the child installs the TERM trap, writes its own
  # .info (:queue -> :setup -> :start -> :done/:error) carrying its own
  # pid, and never returns to the parent's code (exit! 0); the parent only
  # detaches (Process.detach, step.rb:307) and waits `grace` for the job
  # dir to materialize. Neither scout-gear nor scout-essentials registers
  # any at_exit/wait/kill hook, so the child survives this task returning;
  # the engine exposes no other submit-and-detach API. Step#exec is NOT an
  # alternative: it runs the block inline in the current process with no
  # persistence or status writes at all (step.rb:128-158).
  def self.fork_submit(step, result)
    begin
      step.fork unless step.started?
      # Absorb the fork -> first .info write race (mechanics note ss8):
      # between fork returning and the child's first reset_info the info
      # file may not exist yet. scout-camp uses the same 0.5s settle
      # window (base.rb:74) before re-checking anything.
      begin
        Open.wait_for(step.path, timeout: 0.5)
      rescue Exception
        nil
      end
    rescue Exception => e
      result[:status] = "error"
      result[:error_phase] = "execution"
      result[:exception_class] = e.class.name
      result[:exception_message] = "Fork submission failed: #{e.message}"
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
      return result
    end

    result[:submitted] = true
    begin
      info = step.info
      result[:status] = info[:status].to_s if info[:status]
      result[:pid] = info[:pid]
      result[:pid_alive] = Misc.pid_alive?(info[:pid]) if info[:pid]
    rescue Exception => e
      result[:warnings] << "Could not read status after fork: #{e.message}"
    end
    WorkflowCoder.attach_job_identity(step, result)
    result[:messages] << "Forked: job runs in a detached child process; poll with job_status, fetch with job_result."
    result
  end

  def self.info_dependencies(info)
    (info[:dependencies] || []).map do |d|
      d.is_a?(Hash) ? (d[:name] || d[:path] || d.to_s) : d.to_s
    end
  end

  def self.attach_info_exception(info, result)
    return unless info[:exception]
    exc_info = info[:exception]
    if exc_info.is_a?(Hash)
      result[:exception_class] = exc_info[:class] || exc_info[:name] || exc_info.class.name
      result[:exception_message] = exc_info[:message] || exc_info.to_s
    else
      result[:exception_message] = exc_info.to_s
    end
  end

  # Response-discipline helper: every response where a job is involved
  # echoes job_path, short_path and files_dir. Pure read, never raises.
  def self.attach_job_identity(step, result)
    begin
      result[:job_path] = step.path.to_s if step.respond_to?(:path)
      result[:short_path] = WorkflowCoder.step_short_path(step)
      result[:files_dir] = step.files_dir.to_s if step.respond_to?(:files_dir)
    rescue Exception => e
      result[:warnings] << "Could not collect job identity: #{e.message}"
    end
  end

  # Read-only info diagnostics shared by the error paths.
  def self.fill_info_diagnostics(step, result)
    begin
      info = step.info
      result[:messages] = (info[:messages] || []).map(&:to_s) if info[:messages]
      result[:status] = info[:status].to_s if info[:status]
      result[:dependencies] = WorkflowCoder.info_dependencies(info) if info[:dependencies]
      WorkflowCoder.attach_info_exception(info, result)
    rescue Exception
    end
  end

  # ---- Job-control helpers ----

  # Resolve a job-control reference. Same three forms as load_job_reference
  # (existing path, short_path 'Workflow/task/name', 'task/name' plus the
  # workflow option). A job with no .info on disk is rejected: every
  # control op reads step.info, so a never-run job has nothing to report.
  # A running job qualifies: the forked child writes .info before doing
  # any work (:queue/:setup, scout-gear step.rb:210-216, 296).
  #
  # ScoutCoder: Workflow#load_job (scout-gear workflow/util.rb:38-40) is
  # literally `Step.new directory[task_name][name]` -- a bare path-Step
  # with NO task block. run/exec therefore cannot re-execute such a Step
  # (there is no block to instance_exec); inputs, dependencies, task_name
  # and workflow are recovered lazily from the .info sidecar
  # (step.rb:38-119). That no-task-block limitation is precisely what
  # makes it safe for status/result/abort operations, and it is why a
  # control op must never try to re-run the job it holds.
  def self.resolve_control_reference(reference, workflow, result)
    ref = reference.to_s.strip.sub(/\.info$/, '')

    fail_reference = lambda do |message|
      result[:status] = "error"
      result[:error_phase] = "job_reference"
      result[:exception_class] = "ParameterException"
      result[:exception_message] = message
    end

    return fail_reference.call("Job reference is empty.") && nil if ref.empty?

    segments = ref.split("/").reject{|s| s.empty? }
    safe = lambda{|&b| begin; b.call; rescue Exception => e; e; end }

    attempts = []
    if ref.start_with?("/") || Open.exists?(ref) || Open.exists?(ref + ".info")
      attempts << [:path, ref, safe.call{ Step.load(ref) }]
    end
    if segments.length == 3
      attempts << [:short_path, segments * "/", safe.call{ Step.load(segments * "/") }]
    end
    if segments.length == 2 && !workflow.to_s.strip.empty?
      label = [workflow.to_s, segments * "/"] * "/"
      attempts << [:task_name, label, safe.call{
        Workflow.require_workflow(workflow.to_s).load_job(segments[0], segments[1])
      }]
    end

    tried = []
    attempts.each do |kind, label, outcome|
      unless Step === outcome
        tried << "#{label}: #{outcome.class}: #{outcome.message}"
        next
      end
      info_file = begin
                    outcome.respond_to?(:info_file) ? outcome.info_file : nil
                  rescue Exception
                    nil
                  end
      if info_file && Open.exists?(info_file)
        result[:job_reference] = {
          reference: reference.to_s,
          kind: kind.to_s,
          resolved_path: outcome.path.to_s,
          short_path: outcome.short_path.to_s,
        }
        return outcome
      end
      tried << "#{label}: no .info at #{info_file || '?'} (job was never run or does not exist)"
    end

    detail = tried.any? ? tried.join(" ; ") :
      "no interpretation matched (expected an existing job path, 'Workflow/task/name', or 'task/name' together with the workflow option)"
    fail_reference.call("Could not resolve job reference '#{reference}'. Tried: #{detail}.")
    nil
  end

  # Structured status snapshot for one job: the scout-camp serve_step model
  # (sinatra/base.rb:84-106) extended with pid liveness and timestamps.
  # Pure read; never triggers execution.
  #
  # `status` is NORMALIZED to the camp vocabulary (done / error / aborted /
  # running / pending); the raw info status is kept in `raw_status` because
  # the engine writes intermediate states (:queue, :setup, :start) that a
  # poller should not have to enumerate.
  #
  # ScoutCoder: running?/started? are purely file+pid based (info.rb:194-196,
  # status.rb:83-89) and step.info re-reads the sidecar whenever its mtime
  # is newer than the cached @info_load_time (info.rb:48-60), so a fresh
  # Step built in this process sees the child's writes with no IPC.
  def self.status_snapshot(step)
    info = begin
             step.info
           rescue Exception => e
             { :__info_read_error => e.message }
           end
    read_error = info.delete(:__info_read_error)

    pid = info[:pid]
    raw_status = info[:status] ? info[:status].to_s : nil
    snapshot = {
      status: WorkflowCoder.normalized_status(step, info),
      raw_status: raw_status,
      short_path: WorkflowCoder.step_short_path(step),
      done: step.respond_to?(:done?) ? step.done? : false,
      error: step.respond_to?(:error?) ? step.error? : false,
      aborted: step.respond_to?(:aborted?) ? step.aborted? : false,
      running: step.respond_to?(:running?) ? step.running? : false,
      started: step.respond_to?(:started?) ? step.started? : false,
      waiting: step.respond_to?(:waiting?) ? step.waiting? : false,
      pid: pid,
      pid_alive: pid ? Misc.pid_alive?(pid) : false,
      time_issued: info[:issued] ? info[:issued].to_s : nil,
      time_started: info[:start] ? info[:start].to_s : nil,
      time_done: info[:end] ? info[:end].to_s : nil,
      messages: (info[:messages] || []).map(&:to_s),
      exception_class: nil,
      exception_message: nil,
    }
    WorkflowCoder.attach_info_exception(info, snapshot)
    snapshot[:info_read_error] = read_error if read_error
    snapshot
  end

  # Normalize an info sidecar into the camp status vocabulary. Terminal
  # states pass through verbatim; any state with a live pid counts as
  # running (the engine's own running? predicate is exactly this test,
  # info.rb:194-196); a payload file without a terminal status counts as
  # done (done? is just Open.exist?(path), step.rb:312-314); anything else
  # is the raw status or 'pending' when no info was written yet.
  def self.normalized_status(step, info)
    raw = info[:status] ? info[:status].to_s : nil
    return raw if %w(done error aborted).include?(raw)
    pid = info[:pid]
    return "running" if pid && Misc.pid_alive?(pid)
    return "done" if raw.nil? && step.respond_to?(:done?) && step.done?
    raw || "pending"
  end

  # Robust 'Workflow/task/name' identifier. Step#short_path (scout-gear
  # step.rb:93) is [workflow.to_s, task_name, name] * '/', but on a bare
  # path-Step built by Step.load/load_job the workflow accessor is NOT
  # recovered from the info sidecar (only inputs/dependencies/provided_inputs
  # are, step.rb:38-84), so it degrades to '//name'. Recover it from
  # info[:workflow]/info[:task_name] -- which the engine writes on every run
  # (step.rb:210-216) -- and fall back to the last three path segments.
  def self.step_short_path(step)
    begin
      segs = step.short_path.to_s.split("/").reject{|s| s.empty? }
      return segs * "/" if segs.length == 3
    rescue Exception
    end
    info = begin
             step.info
           rescue Exception
             {}
           end
    wf = info[:workflow].to_s
    tn = info[:task_name].to_s
    nm = File.basename(step.path.to_s)
    return [wf, tn, nm] * "/" unless wf.empty? || tn.empty?
    parts = step.path.to_s.split("/").reject{|s| s.empty? }
    parts.length >= 3 ? parts.last(3) * "/" : step.path.to_s
  end

  # Run one of this workflow's OWN wrapper tasks with a fresh payload.
  #
  # The wrapper tasks (run_task, job_status, job_stop, job_result,
  # job_files, ...) are ordinary :json tasks, so the engine caches their
  # output by input set and Step#run short-circuits at done? by serving
  # Persist.load of the existing file (scout-gear step.rb:181-190). For
  # a status/control wrapper this caching is actively wrong: the same
  # job reference must be allowed to return different answers as the
  # underlying job progresses. scout-camp side-steps this at the HTTP
  # layer (its status endpoint never goes through a cached task, it just
  # re-reads step.info; sinatra/base.rb:100-106).
  #
  # The fix: clean the wrapper's own cache immediately before running it.
  # Step#clean only removes the wrapper's path/tmp_path/info_file/files_dir
  # (status.rb:53-64) -- never the referenced job's -- so it is local and
  # idempotent. Every wrapper payload on disk is therefore always fresh,
  # and the probes in tmp/ call the tasks through this helper so nothing
  # they read can be a stale cached answer.
  #
  # ScoutCoder: there is no engine-level "run this task uncached" option;
  # Persist.persist offers :update (persist.rb:66, 83) but Step#run does
  # not forward it, and Task#job memoizes Steps in Workflow.job_cache
  # (task.rb:47), so after clean() the SAME Step object is reused with
  # @done/@info/@result reset -- which is exactly what we want here.
  def self.run_fresh(task_name, inputs = {})
    inputs = JSON.parse inputs if String === inputs
    wrapper = WorkflowCoder.job(task_name.to_sym, nil, inputs || {})
    wrapper.clean if wrapper.respond_to?(:clean) && Open.exists?(wrapper.info_file)
    wrapper.run
  end

  # Bounded read of the job payload file. Never goes through the task
  # block; the file on disk is the source of truth.
  def self.bounded_job_payload(step, result, max_bytes = 5000)
    path = step.path
    return nil unless Open.exists?(path)

    content = begin
                Open.read(path)
              rescue Exception => e
                result[:warnings] << "Could not read job file: #{e.message}"
                return nil
              end

    if content.length > max_bytes
      result[:warnings] << "Result content (#{content.length} bytes) truncated to #{max_bytes} bytes; read the job file directly for the full payload: #{path}"
      content = content[0..max_bytes] + "...(truncated)"
    end
    content
  end

  def self.empty_control_result(job, workflow)
    {
      job: job.to_s,
      workflow: workflow.to_s,
      status: nil,
      execution_time: nil,
      job_path: nil,
      job_reference: nil,
      files: [],
      warnings: [],
      messages: [],
      exception_class: nil,
      exception_message: nil,
      backtrace_summary: [],
      error_phase: nil,
    }
  end

  input :job, :string, "Reference to the job: full job path, short_path 'Workflow/task/name', or 'task/name' plus the workflow input", nil, nofile: true
  input :workflow, :string, "Name of the workflow (only used to disambiguate 'task/name' references)"
  task :job_status => :json do |job, workflow|
    result = WorkflowCoder.empty_control_result(job, workflow)

    step = WorkflowCoder.resolve_control_reference(job, workflow, result)
    next result if step.nil?

    begin
      WorkflowCoder.attach_job_identity(step, result)
      snapshot = WorkflowCoder.status_snapshot(step)
      result.merge!(snapshot)
      if step.respond_to?(:files_dir) && Open.exist?(step.files_dir)
        result[:files] = Dir.glob(File.join(step.files_dir, "**/*")).select{|f| File.file?(f) }
      end
    rescue Exception => e
      result[:status] = "error"
      result[:error_phase] = "execution"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
    end
    result
  end

  input :job, :string, "Reference to the job: full job path, short_path 'Workflow/task/name', or 'task/name' plus the workflow input", nil, nofile: true
  input :workflow, :string, "Name of the workflow (only used to disambiguate 'task/name' references)"
  task :job_stop => :json do |job, workflow|
    result = WorkflowCoder.empty_control_result(job, workflow)
    result[:action] = nil
    result[:pid] = nil
    result[:pid_alive] = nil
    result[:escalated] = false
    result[:previous_status] = nil

    step = WorkflowCoder.resolve_control_reference(job, workflow, result)
    next result if step.nil?

    begin
      WorkflowCoder.attach_job_identity(step, result)
    rescue Exception
    end

    previous_status = begin
                        s = step.status
                        s ? s.to_s : nil
                      rescue Exception
                        nil
                      end
    result[:previous_status] = previous_status

    pid = begin
            step.info[:pid]
          rescue Exception
            nil
          end
    result[:pid] = pid

    # Already terminal: report, do not kill.
    if %w(done error aborted).include?(previous_status)
      result[:action] = "none"
      result[:status] = previous_status
      result[:pid_alive] = pid ? Misc.pid_alive?(pid) : false
      result[:messages] << "Job already terminal (#{previous_status}); nothing to stop."
      next result
    end

    # Not started (no pid, no terminal status): nothing is running, so
    # reconciling to :aborted would mislabel a job that simply has a stale
    # :queue/:setup sidecar. Report it and leave the sidecar untouched.
    if pid.nil? && previous_status
      result[:action] = "none"
      result[:status] = previous_status
      result[:pid_alive] = false
      result[:messages] << "Job is not started (status #{previous_status}, no pid); nothing to stop."
      next result
    end

    WorkflowCoder.stop_step(step, result)
    result
  end

  # Engine-native stop: abort -> liveness check -> KILL escalation ->
  # :aborted reconciliation. See the job_stop section of README.md for the
  # convention rationale.
  #
  # ScoutCoder: the engine writes :aborted ONLY from the streaming abort
  # callback (scout-gear step.rb:272); a TERM-killed forked job records
  # :error + an Aborted exception through the normal error path
  # (step.rb:248-261; the TERM trap is status.rb:2-17), so we merge the
  # terminal :aborted ourselves with merge_info, the engine's own writer
  # (info.rb:34-42, 71-148). NEVER reset_info/update_info here: they
  # replace the whole info hash (info.rb:34-42, 144-148) and would drop
  # inputs/dependencies.
  def self.stop_step(step, result)
    begin
      step.abort
    rescue Exception => e
      result[:warnings] << "Step#abort raised: #{e.class}: #{e.message}"
    end

    # Brief liveness check; escalate to SIGKILL only if the pid survived.
    deadline = Time.now + 2
    pid = nil
    loop do
      pid = begin
              step.info[:pid]
            rescue Exception
              nil
            end
      break if pid.nil? || !Misc.pid_alive?(pid) || Time.now >= deadline
      sleep 0.1
    end

    result[:pid] = pid

    if pid && Misc.pid_alive?(pid)
      begin
        Process.kill("KILL", pid)
        result[:escalated] = true
        result[:warnings] << "Process survived TERM; escalated to SIGKILL (pid #{pid})."
      rescue Exception => e
        result[:warnings] << "SIGKILL escalation failed: #{e.message}"
      end
      begin
        Misc.wait_child(pid)
      rescue Exception
      end
    end

    # Reconcile the terminal state: always :aborted after our stop.
    begin
      step.merge_info(:status => :aborted, :end => Time.now)
    rescue Exception => e
      result[:warnings] << "Could not merge :aborted status: #{e.message}"
    end

    begin
      info = step.info
      result[:status] = info[:status].to_s if info[:status]
      result[:messages] = (info[:messages] || []).map(&:to_s) if info[:messages]
    rescue Exception => e
      result[:warnings] << "Could not re-read info after stop: #{e.message}"
    end

    result[:pid_alive] = pid ? Misc.pid_alive?(pid) : false
    result[:action] = "aborted"

    # children_pids caveat (mechanics note ss3): TERM reaches the forked
    # Step pid only. Grandchildren the task block started with step.cmd /
    # CMD.cmd are recorded in info[:children_pids] and survive the stop;
    # the framework has no process-group kill, so we surface them instead
    # of silently leaving orphans behind.
    begin
      children = Array(step.info[:children_pids])
      alive_children = children.select{|cp| cp && Misc.pid_alive?(cp) }
      if alive_children.any?
        result[:children_pids_alive] = alive_children
        result[:warnings] << "Job had #{alive_children.length} still-alive child process(es) (#{alive_children.join(', ')}); TERM reached the job pid only. Kill them separately if they must not outlive the job."
      end
    rescue Exception
    end
    result
  end

  input :job, :string, "Reference to the job: full job path, short_path 'Workflow/task/name', or 'task/name' plus the workflow input", nil, nofile: true
  input :workflow, :string, "Name of the workflow (only used to disambiguate 'task/name' references)"
  task :job_result => :json do |job, workflow|
    result = WorkflowCoder.empty_control_result(job, workflow)
    result[:output] = nil
    result[:output_type] = nil

    step = WorkflowCoder.resolve_control_reference(job, workflow, result)
    next result if step.nil?

    begin
      WorkflowCoder.attach_job_identity(step, result)
      snapshot = WorkflowCoder.status_snapshot(step)
      status = snapshot[:status]
      result[:status] = status
      result[:messages] = snapshot[:messages]

      if snapshot[:done] || status == "done"
        result[:output] = WorkflowCoder.bounded_job_payload(step, result)
        result[:output_type] = "string"
      elsif status == "error" || snapshot[:error]
        result[:exception_class] = snapshot[:exception_class]
        result[:exception_message] = snapshot[:exception_message]
        result[:warnings] << "Job errored; no result payload. Use job_status for the full exception record."
      elsif status == "aborted" || snapshot[:aborted]
        result[:output_type] = "none"
        result[:warnings] << "Job was aborted; no result payload."
      elsif snapshot[:running] || snapshot[:started] || snapshot[:waiting]
        result[:output_type] = "in_progress"
        result[:error_phase] = "job_state"
        result[:warnings] << "Job is still #{status || 'pending'}; poll with job_status and fetch again when done."
      else
        result[:output_type] = "none"
        result[:warnings] << "Job is not done and no result file exists (status: #{status.inspect})."
      end
    rescue Exception => e
      result[:status] = "error"
      result[:error_phase] = "execution"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
    end
    result
  end

  input :job, :string, "Reference to the job: full job path, short_path 'Workflow/task/name', or 'task/name' plus the workflow input", nil, nofile: true
  input :workflow, :string, "Name of the workflow (only used to disambiguate 'task/name' references)"
  input :file, :string, "Optional: name of ONE file inside the job's files_dir to read (bounded)", nil, nofile: true
  input :max_bytes, :integer, "Byte bound applied when reading one file", 5000
  task :job_files => :json do |job, workflow, file, max_bytes|
    result = WorkflowCoder.empty_control_result(job, workflow)
    result[:file] = file ? file.to_s : nil
    result[:content] = nil

    step = WorkflowCoder.resolve_control_reference(job, workflow, result)
    next result if step.nil?

    begin
      WorkflowCoder.attach_job_identity(step, result)
      files_dir = step.files_dir if step.respond_to?(:files_dir)

      entries = []
      if files_dir && Open.exist?(files_dir)
        Dir.glob(File.join(files_dir, "**/*")).select{|f| File.file?(f) }.sort.each do |f|
          st = File.stat(f)
          entries << {
            path: f,
            name: f.sub(/^#{Regexp.escape(files_dir.to_s)}\/?/, ''),
            size: st.size,
            mtime: st.mtime.to_s,
          }
        end
      end
      result[:files] = entries
      result[:messages] << "No files found in files_dir." if entries.empty?

      result[:status] = begin
                          s = step.status
                          s ? s.to_s : nil
                        rescue Exception
                          nil
                        end

      if file && !file.to_s.strip.empty?
        name = file.to_s.strip
        target = nil
        entries.each{|e| target = e[:path] if e[:name] == name }

        if target.nil?
          result[:status] = "error"
          result[:error_phase] = "input_validation"
          result[:exception_class] = "ParameterException"
          result[:exception_message] = "File '#{name}' not found in files_dir. Available: #{entries.collect{|e| e[:name] }.empty? ? '(none)' : entries.collect{|e| e[:name] }.join(', ')}"
          next result
        end

        bound = max_bytes && max_bytes > 0 ? max_bytes : 5000
        # ScoutCoder: Open has no binary? predicate (scout-essentials Open
        # exposes gzip?, not binary?); detect binary content locally -- NUL
        # bytes or a broken-UTF-8 first block -- and report it as binary
        # instead of dumping raw bytes into the JSON receipt.
        begin
          head = begin
                   IO.read(target, [bound, 512].min) || ""
                 rescue Exception
                   ""
                 end
          if head.include?("\x00") || ! head.dup.force_encoding('UTF-8').valid_encoding?
            result[:binary] = true
            result[:messages] << "File '#{name}' is binary; not dumping content (size #{File.stat(target).size} bytes)."
          else
            result[:binary] = false
            content = Open.read(target)
            if content.length > bound
              result[:warnings] << "File '#{name}' (#{content.length} bytes) truncated to #{bound} bytes."
              content = content[0..bound] + "...(truncated)"
            end
            result[:content] = content
          end
        rescue Exception => e
          result[:warnings] << "Could not read '#{name}': #{e.message}"
        end
      end
    rescue Exception => e
      result[:status] = "error"
      result[:error_phase] = "execution"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
    end
    result
  end

  export_exec :list_tasks, :task_inputs, :run_task, :clean_job, :job_info, :preview_job,
              :job_status, :job_stop, :job_result, :job_files
end
