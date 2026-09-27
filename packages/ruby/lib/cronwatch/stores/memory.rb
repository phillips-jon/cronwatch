# frozen_string_literal: true

module Cronwatch
  module Stores
    # Keeps everything in process memory. The default when no store is given,
    # good for tests and for trying the library out. State is gone on restart,
    # so a missed run cannot be noticed across one.
    #
    # Every store answers the same methods: init (optional), upsert_job,
    # get_job, list_jobs, delete_job, insert_run, update_run, update_run_if
    # (optional: without it the client reads the run, then writes it), get_run,
    # list_runs, last_run, running_runs, get_state, set_state, compare_and_set_state
    # (optional: without it the client falls back to set_state), prune and close
    # (optional). They take and return the types in types.rb.
    class Memory
      def initialize
        @jobs = {}
        @runs = {}
        @order = {}
        @states = {}
        @seq = 0
        @lock = Mutex.new
      end

      def upsert_job(definition, now)
        definition = JobDefinition.from_h(definition)
        sync do
          existing = @jobs[definition.name]
          @jobs[definition.name] = StoredJob.new(
            name: definition.name,
            definition: clone(definition, JobDefinition),
            created_at: existing ? existing.created_at : now,
            updated_at: now,
          )
        end
        nil
      end

      def get_job(name)
        sync { (job = @jobs[name]) && clone(job, StoredJob) }
      end

      # Code unit order, as the SQL stores sort by bytes rather than by locale.
      def list_jobs
        sync { @jobs.values.map { |j| clone(j, StoredJob) } }.sort_by { |j| j.name.encode(Encoding::UTF_16BE).b }
      end

      def delete_job(name)
        sync do
          @jobs.delete(name)
          @states.delete(name)
          @runs.select { |_, run| run.job == name }.each_key do |id|
            @runs.delete(id)
            @order.delete(id)
          end
        end
        nil
      end

      # Like SQL's primary key: an id already recorded is refused, never overwritten.
      def insert_run(run)
        sync do
          raise "run #{run.id} already exists" if @runs.key?(run.id)

          @runs[run.id] = clone(run, Run)
          @order[run.id] = (@seq += 1)
        end
        nil
      end

      # Like SQL's UPDATE: a run that is gone (its job was forgotten) stays gone, and only these fields change.
      def update_run(run)
        sync do
          existing = @runs[run.id]
          next unless existing

          @runs[run.id] = finished_fields(existing, run)
        end
        nil
      end

      # update_run, only while the stored run's status is one of
      # `from_statuses`, in one step. Returns whether it wrote. What lets
      # exactly one of several processes finishing a run evaluate it.
      def update_run_if(run, from_statuses)
        statuses = Array(from_statuses).map(&:to_sym)
        sync do
          existing = @runs[run.id]
          next false unless existing && statuses.include?(existing.status)

          @runs[run.id] = finished_fields(existing, run)
          true
        end
      end

      def get_run(id)
        sync { (run = @runs[id]) && clone(run, Run) }
      end

      # Newest first.
      def list_runs(job, limit)
        sync do
          @runs.values.select { |r| r.job == job }
               .sort { |a, b| (b.started_at <=> a.started_at).nonzero? || (@order[b.id] <=> @order[a.id]) }
               .first([limit, 0].max)
               .map { |r| clone(r, Run) }
        end
      end

      def last_run(job)
        list_runs(job, 1).first
      end

      # Oldest first, then in the order they were written.
      def running_runs
        sync do
          @runs.values.select { |r| r.status == :running }
               .sort { |a, b| (a.started_at <=> b.started_at).nonzero? || (@order[a.id] <=> @order[b.id]) }
               .map { |r| clone(r, Run) }
        end
      end

      def get_state(job)
        sync { (state = @states[job]) && clone(state, JobState) }
      end

      def set_state(state)
        sync { @states[state.job] = clone(state, JobState) }
        nil
      end

      # Writes `state` only when the stored state's version (absent, or no
      # state at all, counts as 0) is `expected_version`. Returns whether it
      # wrote. See JobState#version.
      def compare_and_set_state(state, expected_version)
        sync do
          next false unless (@states[state.job]&.version || 0) == expected_version

          @states[state.job] = clone(state, JobState)
          true
        end
      end

      # Delete finished runs that started before this time. Returns how many.
      # Each job's newest run is kept whatever its age: without it, a job that
      # runs less often than the retention looks like it never ran.
      def prune(before)
        sync do
          newest = {}
          @runs.each_value { |r| newest[r.job] = [newest.fetch(r.job, r.started_at), r.started_at].max }
          gone = @runs.select { |_, r| r.status != :running && r.started_at < before && r.started_at < newest[r.job] }.keys
          gone.each do |id|
            @runs.delete(id)
            @order.delete(id)
          end
          gone.length
        end
      end

      private

      # `existing` with the fields an update writes taken from `run`.
      def finished_fields(existing, run)
        copy = clone(run, Run)
        existing.dup.tap do |r|
          r.status = copy.status
          r.finished_at = copy.finished_at
          r.duration_ms = copy.duration_ms
          r.error = copy.error
          r.output = copy.output
          r.metrics = copy.metrics
        end
      end

      def sync(&block)
        @lock.synchronize(&block)
      end

      # A copy through JSON, as the SDK's memory store makes, so nothing the
      # caller holds is shared and values read back as any store returns them.
      def clone(value, type)
        type.from_h(JS.parse(JS.json(value.to_h)))
      end
    end
  end
end
