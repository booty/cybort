require "fileutils"

module Cybort
  # Coordinates lifecycle operations for one installation. The lock lives next
  # to (rather than inside) the installation so a reset cannot unlink the file
  # while another process is still holding its descriptor.
  class InstallationLock
    class BusyError < ConfigurationError; end

    attr_reader :path

    def initialize(root)
      @root = File.expand_path(root.to_s)
      @path = "#{@root}.lock"
      @mutex = Mutex.new
      @owner_thread = nil
      @depth = 0
      @file = nil
    end

    def synchronize
      raise ArgumentError, "a block is required" unless block_given?

      # A lifecycle operation may call another lifecycle helper (for example,
      # purge may create a backup). Keep one descriptor and one lock across the
      # nested call instead of depending on platform-specific flock semantics.
      if reentrant?
        @mutex.synchronize do
          @depth += 1
        end
        begin
          return yield
        ensure
          @mutex.synchronize { @depth -= 1 }
        end
      end

      acquire
      begin
        @mutex.synchronize do
          @owner_thread = Thread.current
          @depth = 1
        end
        yield
      ensure
        release
      end
    end

    private

    def reentrant?
      @mutex.synchronize { @owner_thread.equal?(Thread.current) && @depth.positive? }
    end

    def acquire
      FileUtils.mkdir_p(File.dirname(@path))
      @file = File.open(@path, File::RDWR | File::CREAT, 0o600)
      File.chmod(0o600, @path)
      return if @file.flock(File::LOCK_EX | File::LOCK_NB)

      @file.close
      @file = nil
      raise BusyError, "Cybort installation is busy: #{@root}"
    rescue BusyError
      raise
    rescue SystemCallError => error
      @file&.close
      @file = nil
      raise BusyError, "could not lock Cybort installation: #{error.message}"
    end

    def release
      file = @file
      @mutex.synchronize do
        @owner_thread = nil
        @depth = 0
        @file = nil
      end
      return unless file

      begin
        file.flock(File::LOCK_UN)
      ensure
        file.close
      end
    end
  end
end
