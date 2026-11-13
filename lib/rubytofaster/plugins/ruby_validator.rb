# frozen_string_literal: true

module RubyToFaster
  module Plugins
    # Verifies every `.rb` file packaged into the gem compiles cleanly via
    # `RubyVM::InstructionSequence.compile` before packaging, catching syntax errors in <1ms.
    class RubyValidator
      def initialize(normalize_newlines: true)
        @normalize_newlines = normalize_newlines
      end

      def transform(gem_path, content)
        return nil unless gem_path.end_with?(".rb") || gem_path.end_with?(".gemspec")

        source = content.dup.force_encoding(Encoding::UTF_8)
        unless source.valid_encoding?
          raise BuildError, "Invalid UTF-8 encoding in Ruby source file: #{gem_path}"
        end

        normalized = @normalize_newlines ? source.gsub("\r\n", "\n") : source

        if defined?(RubyVM::InstructionSequence)
          begin
            RubyVM::InstructionSequence.compile(normalized, gem_path, gem_path, 1)
          rescue SyntaxError => e
            raise BuildError, "Ruby syntax error in #{gem_path}:\n#{e.message}"
          end
        end

        @normalize_newlines && normalized != source ? normalized.b : nil
      end
    end
  end
end
