# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Complex Jobs' do
  let(:capsule) { GoodJob::Capsule.new }
  let(:inline_adapter) { GoodJob::Adapter.new(execution_mode: :inline, _capsule: capsule) }
  let(:async_adapter) { GoodJob::Adapter.new(execution_mode: :async_all, _capsule: capsule) }

  before do
    allow(GoodJob.on_thread_error).to receive(:call).and_call_original
  end

  after do
    capsule.shutdown
  end

  describe 'Job without error handler / unhandled' do
    after do
      # This spec will intentionally raise an error on the thread.
      THREAD_ERRORS.clear
    end

    specify do
      stub_const "TestJob", (Class.new(ActiveJob::Base) do
        def perform
          raise "error"
        end
      end)

      TestJob.queue_adapter = async_adapter
      TestJob.perform_later

      wait_until { expect(GoodJob::Job.last.finished_at).to be_present }
      capsule.shutdown

      good_job = GoodJob::Job.last
      expect(good_job).to have_attributes(
        executions_count: 1,
        error: "RuntimeError: error",
        error_event: "unhandled"
      )
      expect(good_job.executions.size).to eq 1
      expect(good_job.executions.last).to have_attributes(
        error: "RuntimeError: error",
        error_event: "unhandled"
      )

      expect(THREAD_ERRORS.size).to eq 1
      expect(GoodJob.on_thread_error).to have_received(:call).with(instance_of(RuntimeError))
    end
  end

  describe 'Job with retry stopped but no block' do
    after do
      # This spec will intentionally raise an error on the thread.
      THREAD_ERRORS.clear
    end

    specify do
      stub_const "TestJob", (Class.new(ActiveJob::Base) do
        retry_on StandardError, wait: 0, attempts: 1

        def perform
          raise StandardError, "error"
        end
      end)

      TestJob.queue_adapter = async_adapter
      TestJob.perform_later

      wait_until { expect(GoodJob::Job.last.finished_at).to be_present }
      capsule.shutdown

      good_job = GoodJob::Job.last
      expect(good_job).to have_attributes(
        executions_count: 1,
        error: "StandardError: error",
        error_event: "retry_stopped"
      )
      expect(good_job.executions.size).to eq 1
      expect(good_job.executions.last).to have_attributes(
        error: "StandardError: error",
        error_event: "retry_stopped"
      )

      expect(THREAD_ERRORS.size).to eq 1
    end
  end

  describe 'Job with discard' do
    specify do
      stub_const "TestJob", (Class.new(ActiveJob::Base) do
        discard_on StandardError

        def perform
          raise StandardError, "error"
        end
      end)

      TestJob.queue_adapter = async_adapter
      TestJob.perform_later

      wait_until { expect(GoodJob::Job.last.finished_at).to be_present }
      capsule.shutdown

      good_job = GoodJob::Job.last
      expect(good_job).to have_attributes(
        executions_count: 1,
        error: "StandardError: error",
        error_event: "discarded"
      )
      expect(good_job.executions.size).to eq 1
      expect(good_job.executions.last).to have_attributes(
        error: "StandardError: error",
        error_event: "discarded"
      )
    end
  end

  describe 'Job with rescue_on and manual retry_job' do
    specify do
      stub_const "TestJob", (Class.new(ActiveJob::Base) do
        rescue_from "StandardError" do
          retry_job
        end

        def perform
          raise StandardError, "error" if executions == 1
        end
      end)

      TestJob.queue_adapter = async_adapter
      TestJob.perform_later

      wait_until { expect(GoodJob::Job.last.finished_at).to be_present }
      capsule.shutdown

      good_job = GoodJob::Job.last
      expect(good_job).to have_attributes(
        executions_count: 2,
        error: nil,
        error_event: nil
      )
      expect(good_job.executions.size).to eq 2
      expect(good_job.executions.order(created_at: :asc).to_a).to contain_exactly(have_attributes(error: "StandardError: error", error_event: "handled"), have_attributes(error: nil, error_event: nil))
    end
  end

  describe 'Job with specific then generic handlers' do
    specify do
      stub_const "TestError", Class.new(StandardError)
      stub_const "TestJob", (Class.new(ActiveJob::Base) do
        discard_on "StandardError" # => Is not called
        retry_on("TestError", wait: 0, attempts: 2)

        def perform
          raise TestError, "error"
        end
      end)

      TestJob.queue_adapter = async_adapter
      TestJob.perform_later

      wait_until { expect(GoodJob::Job.last.finished_at).to be_present }
      capsule.shutdown

      good_job = GoodJob::Job.last
      expect(good_job).to have_attributes(
        executions_count: 2,
        error: "TestError: error",
        error_event: "retry_stopped"
      )
      expect(good_job.executions.size).to eq 2
      expect(good_job.executions.order(created_at: :asc).to_a).to contain_exactly(have_attributes(error: "TestError: error", error_event: "retried"), have_attributes(error: "TestError: error", error_event: "retry_stopped"))

      expect(THREAD_ERRORS.size).to eq 1
      THREAD_ERRORS.clear
    end
  end

  describe 'inline job retry behavior' do
    before do
      stub_const "TestJob", (Class.new(ActiveJob::Base) do
        retry_on StandardError, wait: 0, attempts: Float::INFINITY

        def perform
          raise 'failing' if executions < 3
        end
      end)

      TestJob.queue_adapter = inline_adapter
    end

    it 'runs retries iteratively rather than recursively' do
      TestJob.perform_later

      expect(GoodJob::Job.count).to eq 1
      job = GoodJob::Job.order(:created_at).last
      executions = job.executions.order(:created_at).to_a

      expect(job.status).to eq :succeeded
      expect(job.performed_at).to be_present
      expect(job.finished_at).to be_present

      expect(executions.size).to eq 3
      expect(executions[0].status).to eq :discarded
      expect(executions[1].status).to eq :discarded
      expect(executions[2].status).to eq :succeeded

      expect(executions[0].finished_at).to be < executions[1].finished_at
      expect(executions[1].finished_at).to be < executions[2].finished_at
    end
  end
end
