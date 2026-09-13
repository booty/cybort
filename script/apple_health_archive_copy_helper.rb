#!/usr/bin/env ruby

require "digest"
require "json"

MAX_REQUEST_BYTES = 16 * 1024
MAX_RESPONSE_BYTES = 16 * 1024
CHUNK_BYTES = 1024 * 1024
MAX_COMPRESSED_BYTES = 4 * 1024 * 1024 * 1024

def read_frame(io, maximum_bytes)
  header = read_exact(io, 4)
  raise "invalid request" unless header && header.bytesize == 4

  length = header.unpack1("N")
  raise "request too large" if length > maximum_bytes

  payload = read_exact(io, length)
  raise "truncated request" unless payload && payload.bytesize == length

  JSON.parse(payload)
end

def read_exact(io, length)
  result = +"".b
  while result.bytesize < length
    chunk = io.read(length - result.bytesize)
    raise "truncated request" unless chunk && !chunk.empty?

    result << chunk
  end
  result
end

def write_all(io, payload)
  offset = 0
  while offset < payload.bytesize
    written = io.write(payload.byteslice(offset, payload.bytesize - offset))
    raise IOError unless written.is_a?(Integer) && written.positive?

    offset += written
  end
end

def write_frame(io, payload)
  encoded = JSON.generate(payload)
  raise "response too large" if encoded.bytesize > MAX_RESPONSE_BYTES

  write_all(io, [encoded.bytesize].pack("N"))
  write_all(io, encoded)
  io.flush
end

def stat_projection(stat)
  {
    "device" => stat.dev,
    "inode" => stat.ino,
    "size" => stat.size,
    "mtime_nsec" => (stat.mtime.to_r * 1_000_000_000).to_i,
    "ctime_nsec" => (stat.ctime.to_r * 1_000_000_000).to_i
  }
end

def target_projection(target)
  return nil unless target

  stat_projection(target.stat)
rescue StandardError
  nil
end

def write_failure(status, target)
  write_frame($stdout, {
    "status" => status,
    "created" => !target.nil?,
    "target_stat" => target_projection(target)
  })
rescue StandardError
  nil
end

source = nil
target = nil
begin
  request = read_frame($stdin, MAX_REQUEST_BYTES)
  source_path = request.fetch("source_path")
  target_path = request.fetch("target_path")
  captured_stat = request.fetch("captured_stat")
  raise "source too large" if captured_stat.fetch("size") > MAX_COMPRESSED_BYTES
  source = File.open(source_path, File::RDONLY | File::NOFOLLOW)
  opened_stat = stat_projection(source.stat)
  target = File.open(target_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
  digest = Digest::SHA256.new
  bytes = 0
  while (chunk = source.read(CHUNK_BYTES))
    target.write(chunk)
    digest.update(chunk)
    bytes += chunk.bytesize
    raise "source too large" if bytes > MAX_COMPRESSED_BYTES
  end
  target.flush
  target.fsync
  finished_stat = stat_projection(source.stat)
  path_stat = stat_projection(File.lstat(source_path))
  write_frame($stdout, {
    "status" => "ok", "created" => true, "target_stat" => target_projection(target),
    "sha256" => digest.hexdigest, "bytes" => bytes,
    "opened_stat" => opened_stat, "finished_stat" => finished_stat,
    "path_stat" => path_stat
  })
rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::EISDIR, Errno::ENOTDIR
  write_failure("unreadable", target)
rescue Errno::EEXIST
  write_failure("unsafe", target)
rescue RuntimeError => error
  status = error.message == "source too large" ? "size_limit" : "changed"
  write_failure(status, target)
rescue StandardError
  write_failure("changed", target)
ensure
  target&.close
  source&.close
end
