require 'scout-ai'

Misc.add_libdir if __FILE__ == $PROGRAM_NAME

Workflow.require_workflow "ScoutCoder"

module WorkflowCoder
  extend Workflow

end


WorkflowCoder.include_workflow ScoutCoder

require 'WorkflowCoder/tasks/workflow_tools.rb'
