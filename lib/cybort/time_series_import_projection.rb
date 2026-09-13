module Cybort
  # The writer-facing view of an import receipt.  Private receipt metadata
  # (including archive paths and digests) never crosses this boundary.
  TimeSeriesImportProjection = Data.define(
    :imported, :inserted, :duplicate, :unchanged, :changed, :deleted,
    :stored_series, :stored_observations
  ) do
    def initialize(imported:, inserted:, duplicate:, unchanged:, changed:, deleted:, stored_series:, stored_observations:)
      values = [imported, inserted, duplicate, unchanged, changed, deleted, stored_series, stored_observations]
      unless values.all? { |value| value.is_a?(Integer) && value >= 0 }
        raise ArgumentError, "import projection counts must be nonnegative integers"
      end
      unless imported == inserted + unchanged + changed
        raise ArgumentError, "import projection counts are inconsistent"
      end

      super
    end

    def self.from_receipt(receipt)
      unless receipt.is_a?(TimeSeriesImportReceipt)
        raise ArgumentError, "expected a time-series import receipt"
      end

      new(
        imported: receipt.imported_observation_count,
        inserted: receipt.inserted_observation_count,
        duplicate: receipt.duplicate_observation_count,
        unchanged: receipt.unchanged_observation_count,
        changed: receipt.changed_observation_count,
        deleted: receipt.deleted_observation_count,
        stored_series: receipt.stored_series_count,
        stored_observations: receipt.stored_observation_count
      )
    end

    def to_h
      {
        imported: imported,
        inserted: inserted,
        duplicate: duplicate,
        unchanged: unchanged,
        changed: changed,
        deleted: deleted,
        stored_series: stored_series,
        stored_observations: stored_observations
      }.freeze
    end
  end
end
