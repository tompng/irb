# frozen_string_literal: true
require 'reline'
require 'ripper'
require_relative 'ruby-lex'
require 'prism'

module IRB # :nodoc:
  module Color
    CLEAR     = 0
    BOLD      = 1
    UNDERLINE = 4
    REVERSE   = 7
    BLACK     = 30
    RED       = 31
    GREEN     = 32
    YELLOW    = 33
    BLUE      = 34
    MAGENTA   = 35
    CYAN      = 36
    WHITE     = 37

    class << self
      def colorable?
        supported = $stdout.tty? && (/mswin|mingw/.match?(RUBY_PLATFORM) || (ENV.key?('TERM') && ENV['TERM'] != 'dumb'))

        # because ruby/debug also uses irb's color module selectively,
        # irb won't be activated in that case.
        if IRB.respond_to?(:conf)
          supported && !!IRB.conf.fetch(:USE_COLORIZE, true)
        else
          supported
        end
      end

      def inspect_colorable?(obj, seen: {}.compare_by_identity)
        case obj
        when String, Symbol, Regexp, Integer, Float, FalseClass, TrueClass, NilClass
          true
        when Hash
          without_circular_ref(obj, seen: seen) do
            obj.all? { |k, v| inspect_colorable?(k, seen: seen) && inspect_colorable?(v, seen: seen) }
          end
        when Array
          without_circular_ref(obj, seen: seen) do
            obj.all? { |o| inspect_colorable?(o, seen: seen) }
          end
        when Range
          inspect_colorable?(obj.begin, seen: seen) && inspect_colorable?(obj.end, seen: seen)
        when Module
          !obj.name.nil?
        else
          false
        end
      end

      def clear(colorable: colorable?)
        return '' unless colorable
        "\e[#{CLEAR}m"
      end

      def colorize(text, seq, colorable: colorable?)
        return text unless colorable
        seq = seq.map { |s| "\e[#{const_get(s)}m" }.join('')
        "#{seq}#{text}#{clear(colorable: colorable)}"
      end

      COLORS = {
        gvar: [:GREEN, :BOLD],
        keyword: [:GREEN],
        fname: [:BLUE, :BOLD],
        numeric_literal: [:BLUE, :BOLD],
        special_keyword: [:CYAN, :BOLD],
        float_literal: [:MAGENTA, :BOLD],
        error: [:RED, :REVERSE],
        string_quote: [:RED, :BOLD],
        string: [:RED],
        regexp_quote: [:RED, :BOLD],
        regexp: [:RED],
        symbol_quote: [:YELLOW],
        symbol: [:YELLOW],
        label: [:MAGENTA],
        label_end: [:MAGENTA],
        const: [:BLUE, :BOLD, :UNDERLINE],
        comment: [:BLUE, :BOLD],
        __end__: [:GREEN],
      }

      # If `complete` is false (code is incomplete), this does not warn compile_error.
      # This option is needed to avoid warning a user when the compile_error is happening
      # because the input is not wrong but just incomplete.
      def colorize_code(code, complete: true, ignore_error: false, colorable: colorable?, local_variables: [])
        return code unless colorable

        result = Prism.parse(code, scopes: [local_variables])

        # IRB::ColorPrinter skips colorizing syntax invalid fragments
        return Reline::Unicode.escape_for_print(code) if ignore_error && !result.success?

        errors = result.errors
        unless complete
          errors = errors.reject { |error| error.message =~ /\Aexpected a|unexpected end-of-input|unterminated/ }
        end

        error_segments = errors.map { |error| [error.location, :error] }
        comment_segments = result.comments.map { |comment| [comment.location, :comment] }
        lines = code.lines
        visitor = ColorizeVisitor.new
        result.value.accept(visitor)
        line_index = 0
        col = 0
        colored = +''
        flush = -> next_line_index, next_col {
          return if next_line_index == line_index && next_col == col
          (line_index...[next_line_index, lines.size].min).each do |ln|
            colored << Reline::Unicode.escape_for_print(lines[line_index].byteslice(col..))
            line_index = ln + 1
            col = 0
          end
          unless col == next_col
            colored << Reline::Unicode.escape_for_print(lines[next_line_index].byteslice(col..next_col - 1))
          end
        }
        (visitor.segments + error_segments + comment_segments).sort_by{|l, t|[l.start_line, l.start_column, t == :comment ? 0 : t == :error ? 1 : 2] }.each do |location, type|
          next if location.start_line - 1 < line_index || (location.start_line - 1 == line_index && location.start_column < col)

          flush.call(location.start_line - 1, location.start_column)
          if location.start_line == location.end_line
            slice = lines[location.start_line - 1]&.byteslice(location.start_column...location.end_column)
          else
            slice = [
              lines[location.start_line - 1].byteslice(location.start_column..),
              *lines[location.start_line...location.end_line - 1],
              lines[location.end_line - 1]&.byteslice(0, location.end_column)
          ].join
          end

          raise(type.to_s) unless COLORS.key?(type) # TODO: remove

          slice&.split(/(\n)/)&.each do |s|
            colored << (s == "\n" ? s : colorize(Reline::Unicode.escape_for_print(s), COLORS[type], colorable: true))
          end
          line_index = location.end_line - 1
          col = location.end_column
        end
        flush.call(lines.size, 0)
        colored
      end

      class ColorizeVisitor < Prism::Visitor
        # Prism.constants.filter_map{|name| next unless name =~ /Node$/; klass = Prism.const_get(name); m = klass.instance_methods.grep(/keyword_loc/); [klass, m] unless m.empty?}
        KEYWORD_NODE_NAMES = %w[alias_global_variable_node alias_method_node begin_node break_node case_match_node case_node class_node defined_node ensure_node module_node next_node no_keywords_parameter_node post_execution_node pre_execution_node rescue_modifier_node rescue_node return_node singleton_class_node super_node undef_node unless_node until_node when_node yield_node]

        STANDALONE_NODE_COLORS = {
          embedded_variable_node: :gvar,
          global_variable_read_node: :gvar,
          global_variable_target_node: :gvar,
          integer_node: :numeric_literal,
          float_node: :float_literal,
          imaginary_node: :numeric_literal,
          rational_node: :numeric_literal,
          true_node: :special_keyword,
          false_node: :special_keyword,
          nil_node: :special_keyword,
          source_file_node: :special_keyword,
          source_line_node: :special_keyword,
          source_encoding_node: :special_keyword,
          self_node: :special_keyword,
          forwarding_super_node: :keyword,
          match_last_line_node: :regexp,
          constant_read_node: :const,
          constant_target_node: :const,
        }

        attr_reader :segments

        def initialize
          @segments = []
          @string_content_type = :string
        end

        def dispatch(location, type)
          @segments << [location, type] if location
        end

        KEYWORD_NODE_NAMES.each do |node_name|
          class_name = node_name.split('_').map(&:capitalize).join
          klass = Prism.const_get(class_name)
          keyword_location_methods = klass.instance_methods.grep(/keyword_loc$/)
          dispatch_codes = keyword_location_methods.map do |location_method|
            "dispatch(node.#{location_method}, :keyword)"
          end
          class_eval <<~RUBY, __FILE__, __LINE__ + 1
            def visit_#{node_name}(node)
              #{dispatch_codes.join("\n  ")}
              super
            end
          RUBY
        end

        STANDALONE_NODE_COLORS.each do |node_name, type|
          class_eval <<~RUBY, __FILE__, __LINE__ + 1
            def visit_#{node_name}(node)
              dispatch(node.location, :#{type})
            end
          RUBY
        end

        def visit_if_node(node)
          dispatch(node.if_keyword_loc, :keyword)
          dispatch(node.then_keyword_loc, :keyword) if node.then_keyword != '?' # skip ternary operator
          dispatch(node.end_keyword_loc, :keyword)
          super
        end

        def visit_else_node(node)
          dispatch(node.else_keyword_loc, :keyword) if node.else_keyword != ':' # skip ternary operator
          super
        end

        def visit_match_predicate_node(node)
          dispatch(node.operator_loc, :keyword)
          super
        end

        def visit_in_node(node)
          dispatch(node.in_loc, :keyword)
          super
        end

        def visit_def_node(node)
          dispatch(node.def_keyword_loc, :keyword)
          dispatch(node.name_loc, :fname)
          dispatch(node.end_keyword_loc, :keyword)
          super
        end

        def visit_while_node(node)
          dispatch(node.keyword_loc, :keyword)
          dispatch(node.closing_loc, :keyword)
          super
        end

        def visit_for_node(node)
          dispatch(node.for_keyword_loc, :keyword)
          dispatch(node.in_keyword_loc, :keyword)
          dispatch(node.do_keyword_loc, :keyword)
          dispatch(node.end_keyword_loc, :keyword)
          super
        end

        def visit_symbol_node(node)
          if node.opening_loc.nil? && node.closing_loc
            dispatch(node.value_loc, :label)
            dispatch(node.closing_loc, :label_end)
          else
            dispatch(node.opening_loc, :symbol_quote)
            dispatch(node.value_loc, :symbol)
            dispatch(node.closing_loc, :symbol_quote)
          end
          # no children
        end

        def visit_string_node(node)
          dispatch(node.opening_loc, :string_quote)
          dispatch(node.content_loc, @string_content_type)
          dispatch(node.closing_loc, :string_quote)
          # no children
        end
        alias visit_x_string_node visit_string_node

        def visit_regular_expression_node(node)
          dispatch(node.opening_loc, :regexp_quote)
          dispatch(node.content_loc, :regexp)
          dispatch(node.closing_loc, :regexp_quote)
          # no children
        end

        def visit_interpolated_string_node(node)
          dispatch(node.opening_loc, :string_quote)
          super
          dispatch(node.closing_loc, :string_quote)
        end
        alias visit_interpolated_x_string_node visit_interpolated_string_node

        def visit_interpolated_symbol_node(node)
          dispatch(node.opening_loc, :symbol_quote)
          backup = @string_content_type
          @string_content_type = :symbol
          super
          @string_content_type = backup
          dispatch(node.closing_loc, :symbol_quote)
        end

        def visit_interpolated_regular_expression_node(node)
          dispatch(node.opening_loc, :regexp_quote)
          @string_content_type = :regexp
          backup = @string_content_type
          super
          @string_content_type = backup
          dispatch(node.closing_loc, :regexp_quote)
        end
        alias visit_interpolated_match_last_line_node visit_interpolated_regular_expression_node

        def visit_embedded_statements_node(node)
          dispatch(node.opening_loc, @string_content_type)
          backup = @string_content_type
          @string_content_type = :string
          super
          @string_content_type = backup
          dispatch(node.closing_loc, @string_content_type)
        end

        def visit_array_node(node)
          case node.opening_loc&.slice
          when '['
          when /\A%[wW]/
            dispatch(node.opening_loc, :string_quote)
            dispatch(node.closing_loc, :string_quote)
          when /\A%[iI]/
            dispatch(node.opening_loc, :symbol_quote)
            dispatch(node.closing_loc, :symbol_quote)
          end
          super
        end

        def visit_block_node(node)
          dispatch(node.opening_loc, :keyword) if node.opening == 'do'
          dispatch(node.closing_loc, :keyword) if node.closing == 'end'
          super
        end
        alias visit_lambda_node visit_block_node

        {
          gvar: %w[global_variable_write_node global_variable_operator_write_node global_variable_and_write_node global_variable_or_write_node],
          const: %w[
            constant_write_node constant_path_node constant_path_target_node
            constant_operator_write_node constant_and_write_node constant_or_write_node
          ],
          label: %w[optional_keyword_parameter_node required_keyword_parameter_node],
        }.each do |type, node_names|
          node_names.each do |node_name|
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def visit_#{node_name}(node)
                dispatch(node.name_loc, :#{type})
                super
              end
            RUBY
          end
        end
      end

      private

      def without_circular_ref(obj, seen:, &block)
        return false if seen.key?(obj)
        seen[obj] = true
        block.call
      ensure
        seen.delete(obj)
      end
    end
  end
end
