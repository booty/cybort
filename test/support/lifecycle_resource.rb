class LifecycleResource
  attr_reader :path, :setup_calls, :backup_paths, :closed

  class << self
    attr_accessor :setup_errors, :close_errors

    def reset!(setup_errors: [], close_errors: [])
      @instances = []
      self.setup_errors = setup_errors
      self.close_errors = close_errors
    end

    def instances
      @instances ||= []
    end
  end

  reset!

  def initialize(path, clock:)
    @path = path
    @clock = clock
    @setup_calls = 0
    @backup_paths = []
    @closed = false
    self.class.instances << self
  end

  def setup!
    @setup_calls += 1
    error = self.class.setup_errors.fetch(self.class.instances.index(self), nil)
    raise error if error

    self
  end

  def backup_to(path)
    @backup_paths << path
    File.write(path, "fixture backup")
    path
  end

  def close
    @closed = true
    error = self.class.close_errors.fetch(self.class.instances.index(self), nil)
    raise error if error

    nil
  end
end

module LifecycleTestSupport
  def with_cybort_constants(replacements)
    originals = replacements.keys.to_h { |name| [name, Cybort.const_get(name, false)] }
    replacements.each do |name, replacement|
      Cybort.send(:remove_const, name)
      Cybort.const_set(name, replacement)
    end
    yield
  ensure
    replacements.each_key do |name|
      Cybort.send(:remove_const, name) if Cybort.const_defined?(name, false)
      Cybort.const_set(name, originals.fetch(name))
    end
  end
end
