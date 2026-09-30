require_relative 'test_helper'
require 'json'
require 'scout'
require_relative '../workflow'

module WorkflowCoderForkFixture
  extend Workflow
  input :seconds, :float, 'Seconds to sleep', 0.0
  input :value, :string, 'Value to return', 'default'
  task :delayed => :string do |seconds, value|
    sleep(seconds.to_f)
    value.to_s
  end
  input :seconds, :float, 'Seconds to sleep', 0.0
  task :delayed_failure => :string do |seconds|
    sleep(seconds.to_f)
    raise 'fixture failure'
  end
end

class WorkflowCoderForkAsyncTest < Test::Unit::TestCase
  WORKFLOW = 'WorkflowCoderForkFixture'

  def field(hash, name)
    hash[name] || hash[name.to_sym]
  end

  def run_coder(task, inputs, mode: 'wait_result')
    WorkflowCoder.job(:run_task, nil, workflow: WORKFLOW, task: task,
      inputs: JSON.generate(inputs), mode: mode, clean: true).run
  end

  def wait_for_terminal(job_path, timeout: 8.0)
    deadline = Time.now + timeout
    loop do
      status = WorkflowCoder.job(:job_status, nil, job: job_path).run
      return status if %w[done error].include?(field(status, 'status').to_s)
      raise "job did not finish: #{status.inspect}" if Time.now >= deadline
      sleep 0.05
    end
  end

  def test_default_mode_is_synchronous_and_propagates_inputs
    started = Time.now
    result = run_coder('delayed', seconds: 0.15, value: 'sync-value')
    assert_equal 'done', field(result, 'status').to_s
    assert_equal 'sync-value', field(result, 'output')
    assert_operator Time.now - started, :>=, 0.1
  end

  def test_fork_returns_early_and_can_be_monitored_to_success
    started = Time.now
    submitted = run_coder('delayed', { seconds: 0.8, value: 'fork-value' }, mode: 'fork')
    assert_equal true, field(submitted, 'submitted')
    job_path = field(submitted, 'job_path')
    assert job_path
    assert_operator Time.now - started, :<, 0.7
    terminal = wait_for_terminal(job_path)
    assert_equal 'done', field(terminal, 'status').to_s
    fetched = WorkflowCoder.job(:job_result, nil, job: job_path).run
    assert_equal 'done', field(fetched, 'status').to_s
    assert_equal 'fork-value', field(fetched, 'output')
  end

  def test_forked_child_failure_is_terminal_and_reported
    submitted = run_coder('delayed_failure', seconds: 0.1, mode: 'fork')
    assert_equal true, field(submitted, 'submitted')
    job_path = field(submitted, 'job_path')
    terminal = wait_for_terminal(job_path)
    assert_equal 'error', field(terminal, 'status').to_s
    fetched = WorkflowCoder.job(:job_result, nil, job: job_path).run
    assert_equal 'error', field(fetched, 'status').to_s
    assert_match(/fixture failure/, fetched.to_s)
  end
end
