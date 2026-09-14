module Cybort
  class TimeSeriesFetchResult
    attr_reader :instance_id, :artifact, :sync_state, :started_at, :finished_at,
                :metadata, :source_fetched, :error, :series_count, :observation_count, :kind

    def self.success(instance_id:, artifact:, sync_state:, started_at:, finished_at:, metadata: {}, source_fetched:)
      raise ArgumentError, "imported results must fetch the source" unless source_fetched
      new(instance_id: instance_id, artifact: artifact, sync_state: sync_state,
          started_at: started_at, finished_at: finished_at, metadata: metadata,
          source_fetched: source_fetched, error: nil,
          series_count: artifact&.series_count, observation_count: artifact&.observation_count,
          kind: :imported)
    end

    def self.cached(instance_id:, sync_state:, started_at:, finished_at:, metadata: {},
                    observation_count:, series_count: 0)
      new(instance_id: instance_id, artifact: nil, sync_state: sync_state,
          started_at: started_at, finished_at: finished_at, metadata: metadata,
          source_fetched: false, error: nil, series_count: series_count,
          observation_count: observation_count, kind: :cached)
    end

    def self.unchanged(instance_id:, started_at:, finished_at:, metadata: {}, series_count:, observation_count:)
      new(instance_id: instance_id, artifact: nil, sync_state: nil,
          started_at: started_at, finished_at: finished_at, metadata: metadata,
          source_fetched: true, error: nil, series_count: series_count,
          observation_count: observation_count, kind: :unchanged)
    end

    def self.failure(instance_id:, error:, started_at:, finished_at:, metadata: {})
      raise ArgumentError, "failure results require an error" if error.nil?
      new(instance_id: instance_id, artifact: nil, sync_state: nil,
          started_at: started_at, finished_at: finished_at, metadata: metadata,
          source_fetched: false, error: error, series_count: 0, observation_count: 0,
          kind: :failure)
    end

    def initialize(instance_id:, artifact:, sync_state:, started_at:, finished_at:, metadata:,
                   source_fetched:, error:, series_count:, observation_count:, kind: nil)
      kind ||= if error
        :failure
      elsif source_fetched
        :imported
      else
        :cached
      end
      raise ArgumentError, "invalid result kind" unless %i[imported unchanged cached failure].include?(kind)
      raise ArgumentError, "instance_id must be a nonblank string" unless instance_id.is_a?(String) && !instance_id.empty?
      raise ArgumentError, "source_fetched must be true or false" unless [true, false].include?(source_fetched)
      raise ArgumentError, "result times must be Time values" unless started_at.is_a?(Time) && finished_at.is_a?(Time)
      raise ArgumentError, "finished_at precedes started_at" if finished_at < started_at
      if kind == :imported
        raise ArgumentError, "imported results must be source-fetched" unless error.nil? && source_fetched
        raise ArgumentError, "remote success requires a finalized artifact" unless artifact.is_a?(TimeSeriesSpoolArtifact)
        unless artifact.instance_id == instance_id && artifact.sync_state == sync_state &&
               artifact.source_started_at == started_at && artifact.source_finished_at == finished_at
          raise ArgumentError, "result does not match artifact manifest"
        end
      elsif kind == :unchanged
        raise ArgumentError, "unchanged results must be source-fetched" unless error.nil? && source_fetched
        raise ArgumentError, "unchanged results cannot carry an artifact" if artifact
        raise ArgumentError, "unchanged results cannot carry synchronization state" unless sync_state.nil?
      elsif kind == :cached
        raise ArgumentError, "cached results cannot carry an error" unless error.nil?
        raise ArgumentError, "cached results cannot carry an artifact" if artifact
        raise ArgumentError, "cached results cannot be source-fetched" if source_fetched
      else
        raise ArgumentError, "failure result kind requires an error" unless error
        raise ArgumentError, "failure results must not be source-fetched" if source_fetched
        raise ArgumentError, "failure results cannot carry an artifact" if artifact
        raise ArgumentError, "failure results cannot carry synchronization state" unless sync_state.nil?
        raise ArgumentError, "failure results must have zero counts" unless series_count == 0 && observation_count == 0
      end
      raise ArgumentError, "counts must be nonnegative integers" unless [series_count, observation_count].all? { |n| n.is_a?(Integer) && n >= 0 }
      @instance_id = instance_id.dup.freeze
      @artifact = artifact
      @sync_state = sync_state.nil? ? nil : TimeSeriesJSON.validate_metadata!(sync_state)
      @started_at = started_at.dup.freeze
      @finished_at = finished_at.dup.freeze
      @metadata = TimeSeriesJSON.validate_metadata!(metadata)
      @source_fetched = source_fetched
      @error = error
      @series_count = series_count
      @observation_count = observation_count
      @kind = kind
      freeze
    end

    def success?
      error.nil?
    end

    def failure?
      !success?
    end

    def imported?
      kind == :imported
    end

    def unchanged?
      kind == :unchanged
    end

    def cached?
      kind == :cached
    end
  end
end
