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
      @lock_root = canonical_root(@root)
      @path = "#{@lock_root}.lock"
      @mutex = Mutex.new
      @owner_thread = nil
      @depth = 0
      @file = nil
      @releasing = false
    end

    def synchronize
      raise ArgumentError, "a block is required" unless block_given?

      # A lifecycle operation may call another lifecycle helper (for example,
      # purge may create a backup). Keep one descriptor and one lock across the
      # nested call instead of depending on platform-specific flock semantics.
      if enter_reentrant
        begin
          return yield
        ensure
          leave_reentrant
        end
      end

      file = nil
      committed = false
      active_error = nil
      begin
        # Keep a successfully opened descriptor local until ownership is
        # committed. A concurrent caller may acquire its own descriptor, but
        # can never replace the descriptor held in @file by this lock owner.
        file = acquire
        @mutex.synchronize do
          raise BusyError, "Cybort installation is busy: #{@root}" if @owner_thread || @releasing

          @owner_thread = Thread.current
          @depth = 1
          @file = file
          @releasing = false
          committed = true
          file = nil
        end
        yield
      rescue Exception
        active_error = $!
        raise
      ensure
        cleanup_error = nil
        begin
          if committed
            release
          elsif file
            close_file(file)
          end
        rescue Exception => error # cleanup must not replace an active lifecycle error
          cleanup_error = error
        end
        raise cleanup_error if active_error.nil? && cleanup_error
      end
    end

    private

    def canonical_root(root)
      File.realpath(root)
    rescue Errno::ENOENT
      # An installation is commonly locked before its directory exists. Resolve
      # the nearest existing ancestor so symlink aliases share one sibling lock,
      # while retaining every not-yet-created path component.
      missing_components = []
      candidate = root
      until File.exist?(candidate)
        parent = File.dirname(candidate)
        break if parent == candidate

        missing_components.unshift(File.basename(candidate))
        candidate = parent
      end
      File.join(File.realpath(candidate), *missing_components)
    rescue Errno::ENOTDIR => error
      # A non-directory path component makes the installation unavailable.
      raise BusyError, "could not resolve Cybort installation: #{error.message}"
    end

    def enter_reentrant
      @mutex.synchronize do
        next false unless @owner_thread.equal?(Thread.current) && @depth.positive? && !@releasing

        @depth += 1
        true
      end
    end

    def leave_reentrant
      @mutex.synchronize do
        unless @owner_thread.equal?(Thread.current) && @depth > 1
          raise RuntimeError, "installation lock ownership changed unexpectedly"
        end

        @depth -= 1
      end
    end

    def acquire
      FileUtils.mkdir_p(File.dirname(@path))
      file = File.open(@path, File::RDWR | File::CREAT, 0o600)
      File.chmod(0o600, @path)
      return file if file.flock(File::LOCK_EX | File::LOCK_NB)

      close_file(file)
      raise BusyError, "Cybort installation is busy: #{@root}"
    rescue BusyError
      close_file(file)
      raise
    rescue SystemCallError => error
      close_file(file)
      raise BusyError, "could not lock Cybort installation: #{error.message}"
    end

    def release
      file = @mutex.synchronize do
        unless @owner_thread.equal?(Thread.current) && @depth == 1 && @file
          raise RuntimeError, "installation lock must be released by its owner thread"
        end
        @releasing = true
        @file
      end
      return unless file

      cleanup_error = nil
      begin
        unlocked = file.flock(File::LOCK_UN)
        raise IOError, "could not unlock Cybort installation" unless unlocked
      rescue Exception => error # preserve the active lifecycle error in synchronize
        cleanup_error = error
      ensure
        begin
          file.close
        rescue Exception => error # preserve an earlier unlock error when both fail
          cleanup_error ||= error
        ensure
          @mutex.synchronize do
            if @file.equal?(file)
              @owner_thread = nil
              @depth = 0
              @file = nil
              @releasing = false
            end
          end
        end
      end
      raise cleanup_error if cleanup_error
    end

    def close_file(file)
      return unless file

      file.close unless file.closed?
    end
  end
end
