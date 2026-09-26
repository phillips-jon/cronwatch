# frozen_string_literal: true

module Cronwatch
  module Stores
    # Keeps everything in process memory. The default when no store is given,
    # good for tests and for trying the library out. State is gone on restart,
    # so a missed run cannot be noticed across one.
    #
    # Every store answers the same methods: init (optional), upsert_job,
    # get_job, list_jobs, delete_job, insert_run, update_run, get_run,
    # list_runs, last_run, running_runs, get_state, set_state, prune and close
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

      def insert_run(run)
        sync do
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

          copy = clone(run, Run)
          @runs[run.id] = existing.dup.tap do |r|
            r.status = copy.status
            r.finished_at = copy.finished_at
            r.duration_ms = copy.duration_ms
            r.error = copy.error
            r.output = copy.output
            r.metrics = copy.metrics
          end
        end
        nil
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

      # Delete finished runs that started before this time. Returns how many.
      def prune(before)
        sync do
          gone = @runs.select { |_, r| r.status != :running && r.started_at < before }.keys
          gone.each do |id|
            @runs.delete(id)
            @order.delete(id)
          end
          gone.length
        end
      end

      private

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
