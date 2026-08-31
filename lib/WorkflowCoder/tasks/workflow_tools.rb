module WorkflowCoder

  desc "List all tasks available in a workflow"
  input :workflow, :string, "Name of the workflow to inspect"
  task :list_tasks => :json do |workflow|
    raise ParameterException, "workflow is required" if workflow.nil? || workflow.to_s.strip.empty?

    wf = Workflow.require_workflow workflow.to_s

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

  desc "Get detailed input specifications for a single workflow task"
  input :workflow, :string, "Name of the workflow"
  input :task, :string, "Name of the task to inspect"
  task :task_inputs => :json do |workflow, task|
    raise ParameterException, "workflow is required" if workflow.nil? || workflow.to_s.strip.empty?
    raise ParameterException, "task is required" if task.nil? || task.to_s.strip.empty?

    wf = Workflow.require_workflow workflow.to_s
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

  desc "Execute a workflow task and return structured diagnostics"
  input :workflow, :string, "Name of the workflow to load and execute"
  input :task, :string, "Name of the task to run"
  input :inputs, :json, "Hash of input name to value pairs", {}
  input :clean, :boolean, "Clean the job cache before running", false
  input :recursive_clean, :boolean, "Clean all dependency caches before running", false
  input :stream, :boolean, "Stream output for streaming tasks", false
  task :run_task => :json do |workflow, task, inputs, clean, recursive_clean, stream|
    result = {
      workflow: workflow.to_s,
      task: task.to_s,
      status: nil,
      execution_time: nil,
      output: nil,
      output_type: nil,
      job_path: nil,
      files: [],
      warnings: [],
      messages: [],
      exception_class: nil,
      exception_message: nil,
      backtrace_summary: [],
      dependencies: [],
      error_phase: nil,
    }

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
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(5) : []
      next result
    rescue Exception => e
      result[:status] = "error"
      result[:error_phase] = "job_creation"
      result[:exception_class] = e.class.name
      result[:exception_message] = e.message
      result[:backtrace_summary] = e.backtrace ? e.backtrace.first(10) : []
      next result
    end

    result[:job_path] = step.path.to_s if step.respond_to?(:path)

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

    # Phase 6: Execute
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

  desc "Clean cached results for a workflow task"
  input :workflow, :string, "Name of the workflow"
  input :task, :string, "Name of the task"
  input :inputs, :json, "Hash of input name to value pairs", {}
  input :recursive, :boolean, "Clean all dependency results recursively", false
  task :clean_job => :json do |workflow, task, inputs, recursive|
    raise ParameterException, "workflow is required" if workflow.nil? || workflow.to_s.strip.empty?
    raise ParameterException, "task is required" if task.nil? || task.to_s.strip.empty?

    wf = Workflow.require_workflow workflow.to_s
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

  desc "Retrieve structured info about a job without running it"
  input :workflow, :string, "Name of the workflow"
  input :task, :string, "Name of the task"
  input :inputs, :json, "Hash of input name to value pairs", {}
  task :job_info => :json do |workflow, task, inputs|
    raise ParameterException, "workflow is required" if workflow.nil? || workflow.to_s.strip.empty?
    raise ParameterException, "task is required" if task.nil? || task.to_s.strip.empty?

    wf = Workflow.require_workflow workflow.to_s
    tname = task.to_sym

    raise ParameterException, "Task '#{task}' not found in workflow '#{workflow}'" unless wf.tasks.include?(tname)

    sym_inputs = {}
    inputs.each{|k, v| sym_inputs[k.to_sym] = v } if inputs

    step = wf.job(tname, nil, sym_inputs)

    result = {
      workflow: workflow.to_s,
      task: task.to_s,
      job_path: step.respond_to?(:path) ? step.path.to_s : nil,
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

end
