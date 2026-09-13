module Cybort
  module AppleHealthFixture
    module_function

    def write_zip(path:, entries:, wrapper: nil, export_xml:, mutation: nil)
      export_name = wrapper ? "#{wrapper}/export.xml" : "export.xml"
      Zip::File.open(path, create: true) do |zip|
        write_entry(zip, export_name, export_xml)
        enumerable = entries.is_a?(Hash) ? entries.to_a : entries
        enumerable.each do |name, body|
          if body.nil?
            zip.mkdir(name.end_with?("/") ? name : "#{name}/")
          else
            write_entry(zip, name, body)
          end
        end
      end
      mutation.call(path) if mutation
      path
    end

    def write_entry(zip, name, body)
      zip.get_output_stream(name) { |io| io.write(body) }
    end
    private_class_method :write_entry
  end
end
