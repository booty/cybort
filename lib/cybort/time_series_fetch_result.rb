module Cybort
  class TimeSeriesFetchResult
    attr_reader :instance_id, :artifact, :sync_state, :started_at, :finished_at,
                :metadata, :source_fetched, :error, :series_count, :observation_count

    def self.success(instance_id:, artifact:, sync_state:, started_at:, finished_at:, metadata: {}, source_fetched:)
      new(instance_id: instance_id, artifact: artifact, sync_state: sync_state,
          started_at: started_at, finished_at: finished_at, metadata: metadata,
          source_fetched: source_fetched, error: nil,
          series_count: artifact&.series_count, observation_count: artifact&.observation_count)
    end

    def self.cached(instance_id:, artifact: nil, sync_state:, started_at:, finished_at:, metadata: {},
                    observation_count:, series_count: 0)
      raise ArgumentError, "cached results cannot carry an artifact" if artifact
      new(instance_id: instance_id, artifact: nil, sync_state: sync_state,
          started_at: started_at, finished_at: finished_at, metadata: metadata,
          source_fetched: false, error: nil, series_count: series_count,
          observation_count: observation_count)
    end

    def self.failure(instance_id:, error:, started_at:, finished_at:, metadata: {})
      new(instance_id: instance_id, artifact: nil, sync_state: nil,
          started_at: started_at, finished_at: finished_at, metadata: metadata,
          source_fetched: false, error: error, series_count: 0, observation_count: 0)
    end

    def initialize(instance_id:, artifact:, sync_state:, started_at:, finished_at:, metadata:,
                   source_fetched:, error:, series_count:, observation_count:)
      raise ArgumentError, "instance_id must be a nonblank string" unless instance_id.is_a?(String) && !instance_id.empty?
      raise ArgumentError, "source_fetched must be true or false" unless [true, false].include?(source_fetched)
      raise ArgumentError, "result times must be Time values" unless started_at.is_a?(Time) && finished_at.is_a?(Time)
      raise ArgumentError, "finished_at precedes started_at" if finished_at < started_at
      if error.nil? && source_fetched
        raise ArgumentError, "remote success requires a finalized artifact" unless artifact.is_a?(TimeSeriesSpoolArtifact)
        unless artifact.instance_id == instance_id && artifact.sync_state == sync_state &&
               artifact.source_started_at == started_at && artifact.source_finished_at == finished_at
          raise ArgumentError, "result does not match artifact manifest"
        end
      elsif artifact
        raise ArgumentError, "cached and failure results cannot carry an artifact"
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
      freeze
    end

    def success?
      error.nil?
    end

    def failure?
      !success?
    end
  end
end
