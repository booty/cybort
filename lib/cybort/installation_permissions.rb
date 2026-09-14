require "fileutils"

module Cybort
  # Applies the filesystem modes that protect an installation's local data.
  # Existing regular files are repaired in place; symlinked data files are
  # rejected because chmod would otherwise modify a path outside the install.
  module InstallationPermissions
    ROOT_MODE = 0o700
    FILE_MODE = 0o600

    module_function

    def create_directory!(path)
      expanded = File.expand_path(path.to_s)
      FileUtils.mkdir_p(expanded, mode: ROOT_MODE)
      ensure_directory!(expanded)
    end

    def ensure_directory!(path)
      expanded = File.expand_path(path.to_s)
      raise ValidationError, "Cybort installation must be a directory" unless File.directory?(expanded)

      # File.chmod follows an installation-root alias intentionally. Installer
      # callers already resolve a root symlink before destructive operations,
      # while CLI callers may continue to select an alias for collection.
      File.chmod(ROOT_MODE, expanded)
      expanded
    rescue Errno::ENOENT
      raise ValidationError, "Cybort installation directory is unavailable"
    end

    def ensure_private_file!(path, allow_missing: false)
      expanded = File.expand_path(path.to_s)
      unless File.exist?(expanded) || File.symlink?(expanded)
        return false if allow_missing

        raise ValidationError, "Cybort installation file is missing"
      end

      stat = File.lstat(expanded)
      unless stat.file? && !stat.symlink?
        raise ValidationError, "Cybort installation file must be a private regular file"
      end

      File.chmod(FILE_MODE, expanded)
      true
    rescue Errno::ENOENT
      return false if allow_missing

      raise ValidationError, "Cybort installation file is unavailable"
    end

    def write_private_file!(path, content)
      expanded = File.expand_path(path.to_s)
      if File.exist?(expanded) || File.symlink?(expanded)
        ensure_private_file!(expanded)
        File.binwrite(expanded, content)
      else
        File.open(expanded, File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) do |file|
          file.write(content)
        end
      end
      File.chmod(FILE_MODE, expanded)
      expanded
    end
  end
end
