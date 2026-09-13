require "digest"
require "zip"
require "zlib"

module Cybort
  AppleHealthArchiveCandidate = Data.define(
    :acquired_archive, :export_entry_name, :exported_at, :inventory
  )

  AppleHealthExportStreamResult = Data.define(
    :payload, :export_xml_sha256, :export_xml_bytes
  )

  class AppleHealthZipInspector
    LIMITS = {
      entry_count: 100_000,
      entry_name_bytes: 1_024,
      total_uncompressed_bytes: 16 * 1024 * 1024 * 1024,
      export_xml_bytes: 12 * 1024 * 1024 * 1024,
      metadata_entries: 32 * 1024 * 1024,
      expansion_ratio: 200.0
    }.freeze
    ALLOWED_METHODS = [0, 8].freeze
    LOCAL_HEADER_SIGNATURE = 0x04034b50
    DATA_DESCRIPTOR_SIGNATURE = 0x08074b50
    ZIP64_EXTRA_FIELD = 0x0001
    MAX_ARCHIVE_BYTES = 4 * 1024 * 1024 * 1024

    def initialize(parser_factory:, limits: LIMITS)
      raise ArgumentError, "parser factory must be callable" unless parser_factory.respond_to?(:call)
      raise ArgumentError, "limits must be a hash" unless limits.is_a?(Hash)

      @parser_factory = parser_factory
      @limits = LIMITS.merge(limits).freeze
    end

    def inspect(acquired_archive)
      with_zip(acquired_archive) do |file, zip|
        entries = inventory_entries(file, zip, zip.entries)
        export_entry, export_name = select_export_entry(entries)
        if export_entry.size > @limits.fetch(:export_xml_bytes)
          raise_error(:zip, :zip_resource_limit, limit_name: :export_xml_bytes)
        end
        probe = probe_export(file, export_entry)
        exported_at = probe.fetch(:exported_at) do
          raise_error(:probe, :invalid_export_root)
        end
        unless exported_at.is_a?(Time)
          raise_error(:probe, :invalid_export_root)
        end

        AppleHealthArchiveCandidate.new(
          acquired_archive: acquired_archive,
          export_entry_name: export_name,
          exported_at: exported_at,
          inventory: inventory_hash(entries, export_entry)
        )
      end
    rescue AppleHealthError
      raise
    rescue CountingStream::ResourceLimitExceeded
      raise_error(:zip, :zip_resource_limit, limit_name: :export_xml_bytes)
    rescue Zip::Error, Zlib::Error, EOFError, IOError, SystemCallError, ArgumentError, EncodingError
      raise_error(:zip, :invalid_zip)
    end

    def with_export_stream(candidate)
      acquired_archive = candidate.fetch(:acquired_archive) if candidate.respond_to?(:fetch)
      acquired_archive ||= candidate.acquired_archive
      entry_name = candidate.fetch(:export_entry_name) if candidate.respond_to?(:fetch)
      entry_name ||= candidate.export_entry_name
      with_zip(acquired_archive) do |file, zip|
        entry = zip.find_entry(entry_name) || zip.entries.find do |candidate_entry|
          candidate_entry.name.to_s.dup.force_encoding(Encoding::UTF_8).unicode_normalize(:nfc) == entry_name
        end
        raise_error(:zip, :missing_export_xml) unless entry && !entry.directory?
        if entry.size > @limits.fetch(:export_xml_bytes)
          raise_error(:zip, :zip_resource_limit, limit_name: :export_xml_bytes)
        end

        stream = open_entry_stream(file, entry)
        counted = CountingStream.new(stream, maximum_bytes: @limits.fetch(:export_xml_bytes))
        begin
          payload = yield counted
          counted.drain!
          unless counted.bytes_read == entry.size && counted.crc32 == entry.crc
            raise_error(:zip, :invalid_zip)
          end
          AppleHealthExportStreamResult.new(
            payload: payload,
            export_xml_sha256: counted.hexdigest,
            export_xml_bytes: counted.bytes_read
          )
        ensure
          stream.close
        end
      end
    rescue AppleHealthError
      raise
    rescue CountingStream::ResourceLimitExceeded
      raise_error(:zip, :zip_resource_limit, limit_name: :export_xml_bytes)
    rescue Zip::Error, Zlib::Error, EOFError, IOError, SystemCallError, ArgumentError, EncodingError
      raise_error(:zip, :invalid_zip)
    end

    private

    def with_zip(acquired_archive)
      path = acquired_archive.respond_to?(:path) ? acquired_archive.path : acquired_archive.to_s
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        validate_archive_fingerprint!(file, acquired_archive)
        file.rewind
        preflight_central_directory(file)
        file.rewind
        zip = Zip::File.new(file, buffer: true)
        begin
          yield file, zip
        ensure
          zip.close
        end
      end
    rescue AppleHealthError
      raise
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, IOError, ArgumentError, EncodingError
      raise_error(:zip, :invalid_zip)
    end

    def validate_archive_fingerprint!(file, acquired_archive)
      stat = file.stat
      unless stat.file? && !stat.symlink?
        raise_error(:zip, :invalid_zip)
      end
      expected_bytes = acquired_archive.compressed_bytes
      expected_digest = acquired_archive.archive_sha256
      unless expected_bytes.is_a?(Integer) && expected_bytes >= 0 && expected_bytes <= MAX_ARCHIVE_BYTES &&
             expected_digest.is_a?(String) && expected_digest.match?(/\A[0-9a-f]{64}\z/) &&
             stat.size == expected_bytes
        raise_error(:zip, :invalid_zip)
      end

      digest = Digest::SHA256.new
      bytes = 0
      while (chunk = file.read(1024 * 1024))
        digest.update(chunk)
        bytes += chunk.bytesize
      end
      raise_error(:zip, :invalid_zip) unless bytes == expected_bytes && digest.hexdigest == expected_digest
    end

    def inventory_entries(file, zip, entries)
      raise_error(:zip, :zip_resource_limit, limit_name: :entry_count) if entries.length > @limits.fetch(:entry_count)

      raw_names = central_directory_names(file, zip)
      raise_error(:zip, :invalid_zip) unless raw_names.length == entries.length
      normalized_names = {}
      total_name_bytes = 0
      total_compressed = 0
      total_uncompressed = 0
      family_counts = Hash.new(0)
      inventory = []

      entries.each_with_index do |entry, index|
        ordinal = index + 1
        normalized = normalize_entry_name(raw_names.fetch(index), directory: entry.directory?, ordinal: ordinal)
        if normalized_names.key?(normalized)
          raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal)
        end
        normalized_names[normalized] = true
        total_name_bytes += normalized.bytesize
        raise_error(:zip, :zip_resource_limit, limit_name: :entry_name_bytes) if total_name_bytes > @limits.fetch(:entry_name_bytes) * @limits.fetch(:entry_count)

        if (entry.gp_flags & 0x0041).positive?
          raise_error(:zip, :encrypted_zip, candidate_ordinal: ordinal)
        end
        unless ALLOWED_METHODS.include?(entry.compression_method)
          raise_error(:zip, :unsupported_compression, candidate_ordinal: ordinal)
        end
        validate_external_type!(entry, ordinal)
        compressed = nonnegative_integer(entry.compressed_size, :compressed_bytes, ordinal)
        uncompressed = nonnegative_integer(entry.size, :total_uncompressed_bytes, ordinal)
        total_compressed = checked_add(total_compressed, compressed, :total_uncompressed_bytes, ordinal)
        total_uncompressed = checked_add(total_uncompressed, uncompressed, :total_uncompressed_bytes, ordinal)
        raise_error(:zip, :zip_resource_limit, limit_name: :total_uncompressed_bytes,
                    candidate_ordinal: ordinal) if total_uncompressed > @limits.fetch(:total_uncompressed_bytes)
        validate_local_header!(file, entry, normalized, file.stat.size, ordinal)
        family_counts[family_for(normalized)] += 1
        inventory << { entry: entry, name: normalized, compressed_bytes: compressed,
                       uncompressed_bytes: uncompressed }
      end

      raise_error(:zip, :invalid_zip) if total_compressed > file.stat.size
      ratio = total_uncompressed.fdiv([total_compressed, 1].max)
      raise_error(:zip, :zip_resource_limit, limit_name: :expansion_ratio) if ratio > @limits.fetch(:expansion_ratio)
      {
        entries: inventory.freeze,
        total_compressed_bytes: total_compressed,
        total_uncompressed_bytes: total_uncompressed,
        family_counts: family_counts.freeze
      }.freeze
    end

    def select_export_entry(inventory)
      candidates = inventory.fetch(:entries).select do |item|
        name = item.fetch(:name)
        !item.fetch(:entry).directory? && name.split("/").length.between?(1, 2) &&
          File.basename(name) == "export.xml"
      end
      raise_error(:zip, :missing_export_xml) if candidates.empty?
      raise_error(:zip, :duplicate_export_xml) if candidates.length > 1

      item = candidates.fetch(0)
      [item.fetch(:entry), item.fetch(:name)]
    end

    def inventory_hash(inventory, export_entry)
      {
        entry_count: inventory.fetch(:entries).length,
        total_compressed_bytes: inventory.fetch(:total_compressed_bytes),
        total_uncompressed_bytes: inventory.fetch(:total_uncompressed_bytes),
        export_xml_bytes: export_entry.size,
        family_counts: inventory.fetch(:family_counts)
      }.freeze
    end

    def probe_export(file, entry)
      stream = open_entry_stream(file, entry)
      counted = CountingStream.new(stream, maximum_bytes: @limits.fetch(:export_xml_bytes))
      begin
        prefix = counted.read(4)
        raise_error(:zip, :invalid_zip) if prefix&.start_with?("PK\x03\x04".b)
        result = @parser_factory.call.probe(ReplayStream.new(prefix, counted))
        result.is_a?(Hash) ? result : {}
      ensure
        stream.close
      end
    end

    def open_entry_stream(file, entry)
      stream = nil
      entry.instance_variable_set(:@zipfile, file)
      entry.get_input_stream
    rescue StandardError
      stream&.close
      raise
    end

    def normalize_entry_name(name, directory:, ordinal:)
      raw = name.to_s
      raw = raw.dup.force_encoding(Encoding::UTF_8)
      invalid_name(ordinal) unless raw.valid_encoding? && raw.bytesize <= @limits.fetch(:entry_name_bytes)
      invalid_name(ordinal) if raw.include?("\0") || raw.include?("\\") || raw.match?(%r{\A/}) || raw.match?(/\A[A-Za-z]:/)
      parts = raw.split("/", -1)
      if parts.last == "" && directory
        parts.pop
      end
      invalid_name(ordinal) if parts.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." }
      normalized = parts.join("/").unicode_normalize(:nfc)
      invalid_name(ordinal) if normalized.empty? || normalized.bytesize > @limits.fetch(:entry_name_bytes)

      normalized
    rescue ArgumentError
      invalid_name(ordinal)
    end

    def invalid_name(ordinal)
      raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal)
    end

    def validate_external_type!(entry, ordinal)
      if entry.fstype == Zip::FSTYPE_UNIX
        unix_type = (entry.external_file_attributes >> 28) & 0x0f
        unless [0, Zip::FILE_TYPE_FILE, Zip::FILE_TYPE_DIR].include?(unix_type)
          raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal)
        end
      end
      type = entry.ftype
      return if type.nil? || type == :file || type == :directory

      raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal)
    end

    def validate_local_header!(file, entry, normalized_name, file_size, ordinal)
      offset = entry.local_header_offset
      unless offset.is_a?(Integer) && offset >= 0 && offset <= file_size - 30
        raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal)
      end
      file.seek(offset, IO::SEEK_SET)
      header = read_exact(file, 30)
      fields = header.unpack("VvvvvvVVVvv")
      signature, _version, flags, method, _time, _date, crc, compressed, uncompressed, name_length, extra_length = fields
      raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal) unless signature == LOCAL_HEADER_SIGNATURE
      local_name = read_exact(file, name_length)
      local_extra = read_exact(file, extra_length)
      local_normalized = normalize_entry_name(local_name, directory: entry.directory?, ordinal: ordinal)
      unless flags == entry.gp_flags && method == entry.compression_method && local_normalized == normalized_name
        raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal)
      end
      data_offset = file.pos
      data_end = data_offset + entry.compressed_size
      raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal) unless data_end >= data_offset && data_end <= file_size

      if (flags & 0x0008).zero?
        local_compressed = zip64_or_value(compressed, local_extra, 1, ordinal)
        local_uncompressed = zip64_or_value(uncompressed, local_extra, 0, ordinal)
        unless crc == entry.crc && local_compressed == entry.compressed_size && local_uncompressed == entry.size
          raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal)
        end
      else
        validate_data_descriptor(file, data_end, entry, file_size, ordinal)
      end
    rescue EOFError, Errno::EINVAL
      raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal)
    end

    def central_directory_names(file, zip)
      cdir = zip.instance_variable_get(:@cdir)
      raise_error(:zip, :invalid_zip) unless cdir
      offset = cdir.instance_variable_get(:@cdir_offset)
      count = cdir.instance_variable_get(:@size)
      raise_error(:zip, :invalid_zip) unless offset.is_a?(Integer) && count.is_a?(Integer) && offset >= 0 && count >= 0
      raise_error(:zip, :invalid_zip) if offset > file.stat.size

      file.seek(offset, IO::SEEK_SET)
      names = []
      count.times do
        header = read_exact(file, 46)
        fields = header.unpack("VCCvvvvvVVVvvvvvVV")
        signature = fields.fetch(0)
        name_length = fields.fetch(11)
        extra_length = fields.fetch(12)
        comment_length = fields.fetch(13)
        raise_error(:zip, :invalid_zip) unless signature == 0x02014b50
        names << read_exact(file, name_length)
        read_exact(file, extra_length)
        read_exact(file, comment_length)
      end
      names
    rescue EOFError, Errno::EINVAL
      raise_error(:zip, :invalid_zip)
    end

    def zip64_or_value(value, extra, value_index, ordinal)
      return value unless value == 0xffffffff

      values = zip64_values(extra, ordinal)
      result = values[value_index]
      raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal) unless result.is_a?(Integer)
      result
    end

    def zip64_values(extra, ordinal)
      offset = 0
      while offset + 4 <= extra.bytesize
        header_id, size = extra.byteslice(offset, 4).unpack("vv")
        offset += 4
        raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal) if offset + size > extra.bytesize
        data = extra.byteslice(offset, size)
        return data.unpack("Q<*") if header_id == ZIP64_EXTRA_FIELD
        offset += size
      end
      raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal)
    end

    def validate_data_descriptor(file, offset, entry, file_size, ordinal)
      remaining = file_size - offset
      return raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal) if remaining < 12

      sample = read_at(file, offset, [24, remaining].min)
      expected = [entry.crc, entry.compressed_size, entry.size]
      candidates = []
      if sample.bytesize >= 16 && sample.unpack1("V") == DATA_DESCRIPTOR_SIGNATURE
        candidates << [16, sample.byteslice(4, 12).unpack("VVV")]
      end
      candidates << [12, sample.unpack("VVV")] if sample.bytesize >= 12
      if sample.bytesize >= 24 && sample.unpack1("V") == DATA_DESCRIPTOR_SIGNATURE
        candidates << [24, sample.byteslice(4, 20).unpack("VQ<Q<")]
      end
      candidates << [20, sample.unpack("VQ<Q<")] if sample.bytesize >= 20
      raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal) unless candidates.any? { |length, values| length <= remaining && values == expected }
    end

    def read_at(file, offset, length)
      file.seek(offset, IO::SEEK_SET)
      read_exact(file, length)
    end

    def preflight_central_directory(file)
      cdir = Zip::CentralDirectory.new
      file.rewind
      cdir.count_entries(file)
      count = cdir.instance_variable_get(:@size)
      offset = cdir.instance_variable_get(:@cdir_offset)
      unless count.is_a?(Integer) && count >= 0 && offset.is_a?(Integer) && offset >= 0 && offset <= file.stat.size
        raise_error(:zip, :invalid_zip)
      end
      raise_error(:zip, :zip_resource_limit, limit_name: :entry_count) if count > @limits.fetch(:entry_count)

      file.seek(offset, IO::SEEK_SET)
      metadata_bytes = 0
      local_offsets = []
      count.times do
        header = read_exact(file, 46)
        fields = header.unpack("VCCvvvvvVVVvvvvvVV")
        raise_error(:zip, :invalid_zip) unless fields.fetch(0) == 0x02014b50
        name_length = fields.fetch(11)
        extra_length = fields.fetch(12)
        comment_length = fields.fetch(13)
        read_exact(file, name_length)
        central_extra = read_exact(file, extra_length)
        local_offsets << central_offset(fields, central_extra)
        metadata_bytes += 46 + name_length + extra_length + comment_length
        raise_error(:zip, :zip_resource_limit, limit_name: :metadata_entries) if metadata_bytes > @limits.fetch(:metadata_entries)
        read_exact(file, comment_length)
      end
      preflight_local_metadata(file, local_offsets)
      file.rewind
      count
    rescue EOFError, Errno::EINVAL
      raise_error(:zip, :invalid_zip)
    end

    def preflight_local_metadata(file, offsets)
      file_size = file.stat.size
      metadata_bytes = 0
      offsets.each do |offset|
        next if offset == 0xffffffff
        raise_error(:zip, :invalid_zip) unless offset.is_a?(Integer) && offset >= 0 && offset <= file_size - 30

        file.seek(offset, IO::SEEK_SET)
        header = read_exact(file, 30)
        fields = header.unpack("VvvvvvVVVvv")
        raise_error(:zip, :invalid_zip) unless fields.fetch(0) == LOCAL_HEADER_SIGNATURE
        name_length = fields.fetch(9)
        extra_length = fields.fetch(10)
        metadata_bytes += name_length + extra_length
        raise_error(:zip, :zip_resource_limit, limit_name: :metadata_entries) if metadata_bytes > @limits.fetch(:metadata_entries)
        read_exact(file, name_length + extra_length)
      end
    rescue EOFError, Errno::EINVAL
      raise_error(:zip, :invalid_zip)
    end

    def central_offset(fields, extra)
      offset = fields.fetch(17)
      return offset unless offset == 0xffffffff

      values = zip64_values_from_extra(extra)
      index = 0
      index += 1 if fields.fetch(10) == 0xffffffff
      index += 1 if fields.fetch(9) == 0xffffffff
      resolved = values[index]
      raise_error(:zip, :invalid_zip) unless resolved.is_a?(Integer)

      resolved
    end

    def zip64_values_from_extra(extra)
      cursor = 0
      while cursor + 4 <= extra.bytesize
        header_id, size = extra.byteslice(cursor, 4).unpack("vv")
        cursor += 4
        raise_error(:zip, :invalid_zip) if cursor + size > extra.bytesize
        data = extra.byteslice(cursor, size)
        return data.unpack("Q<*") if header_id == ZIP64_EXTRA_FIELD
        cursor += size
      end
      raise_error(:zip, :invalid_zip)
    end

    def read_exact(file, length)
      result = +"".b
      while result.bytesize < length
        chunk = file.read(length - result.bytesize)
        raise EOFError unless chunk && !chunk.empty?

        result << chunk
      end
      result
    end

    def nonnegative_integer(value, limit_name, ordinal)
      return value if value.is_a?(Integer) && value >= 0

      raise_error(:zip, :invalid_zip, candidate_ordinal: ordinal, limit_name: limit_name)
    end

    def checked_add(left, right, limit_name, ordinal)
      result = left + right
      raise_error(:zip, :zip_resource_limit, limit_name: limit_name, candidate_ordinal: ordinal) if result < left

      result
    end

    def family_for(name)
      case name
      when %r{\Aclinical-records/} then :clinical
      when %r{\Aelectrocardiograms/} then :electrocardiogram
      when %r{\Aworkouts/} then :workout
      when %r{\Aroute/} then :route
      when %r{\Aactivity-summary/} then :activity_summary
      else :other
      end
    end

    class CountingStream
      attr_reader :bytes_read

      def initialize(io, maximum_bytes:)
        @io = io
        @maximum_bytes = maximum_bytes
        @digest = Digest::SHA256.new
        @crc32 = 0
        @bytes_read = 0
      end

      attr_reader :crc32

      def read(length = nil, outbuf = nil)
        chunk = if length.nil?
                   @io.read
                 elsif outbuf.nil?
                   @io.read(length)
                 else
                   @io.read(length, outbuf)
                 end
        return chunk if chunk.nil? || chunk.empty?

        @bytes_read += chunk.bytesize
        raise ResourceLimitExceeded if @bytes_read > @maximum_bytes

        @digest.update(chunk)
        @crc32 = Zlib.crc32(chunk, @crc32)
        chunk
      end

      def drain!
        loop do
          chunk = read(1024 * 1024)
          break if chunk.nil? || chunk.empty?
        end
        self
      end

      def hexdigest
        @digest.hexdigest
      end

      class ResourceLimitExceeded < StandardError; end
    end

    class ReplayStream
      def initialize(prefix, stream)
        @prefix = (prefix || +"".b).dup
        @stream = stream
      end

      def read(length = nil, outbuf = nil)
        if length.nil?
          result = @prefix + (@stream.read || +"".b)
          @prefix = +"".b
          return result.empty? ? nil : result
        end
        return +"".b if length.zero?

        prefix = @prefix.byteslice(0, length)
        @prefix = @prefix.byteslice(prefix.bytesize, @prefix.bytesize - prefix.bytesize) || +"".b
        return write_outbuf(prefix, outbuf) if prefix.bytesize == length

        remainder = @stream.read(length - prefix.bytesize, outbuf)
        write_outbuf(prefix + (remainder || +"".b), outbuf)
      end

      private

      def write_outbuf(result, outbuf)
        return result unless outbuf

        outbuf.replace(result)
      end
    end

    def raise_error(phase, category, candidate_ordinal: nil, limit_name: nil, counts: {})
      raise AppleHealthError.new(
        phase: phase, category: category, candidate_ordinal: candidate_ordinal,
        limit_name: limit_name, counts: counts
      )
    end
  end
end
