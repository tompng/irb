# frozen_string_literal: true

module IRB
  # The implementation of this class is borrowed from RDoc's lib/rdoc/ri/driver.rb.
  # Please do NOT use this class directly outside of IRB.
  class Pager
    class Abort < StandardError
    end
    PAGE_COMMANDS = [ENV['RI_PAGER'], ENV['PAGER'], 'less', 'more'].compact.uniq

    class IO
      def initialize(**options)
        @options = options
        @buffer = +''
        @io = should_page? ? nil : $stdout
      end

      def puts(text)
        write(text + "\n")
      end

      def write(text)
        if @io
          @io.write(text)
        else
          prev_bytesize = @buffer.bytesize
          @buffer << text
          if @buffer.bytesize / 1024 != prev_bytesize / 1024
            prepare_pager if content_exceeds_screen_height?(@buffer)
          end
        end
      rescue Errno::EPIPE
        raise Pager::Abort
      end
      alias print write
      alias << write

      def prepare_pager
        @pager_io = setup_pager(**@options)
        @pager_pid = @pager_io&.pid
        @io = @pager_io || $stdout
        @io.write @buffer
      end

      def close
        unless @io
          if content_exceeds_screen_height?(@buffer)
            prepare_pager
          else
            $stdout.write @buffer
          end
        end
        @pager_io&.close
      end

      def cleanup
        begin
          Process.kill("TERM", @pager_pid) if @pager_pid
        rescue Errno::EINVAL
          # SIGTERM not supported (windows)
          Process.kill("KILL", @pager_pid)
        end
      rescue Errno::ESRCH
        # Pager process already terminated
      end

      private

      def should_page?
        IRB.conf[:USE_PAGER] && STDIN.tty? && (ENV.key?("TERM") && ENV["TERM"] != "dumb")
      end

      def content_exceeds_screen_height?(content)
        screen_height, screen_width = begin
          Reline.get_screen_size
        rescue Errno::EINVAL
          [24, 80]
        end

        pageable_height = screen_height - 3 # leave some space for previous and the current prompt

        # If the content has more lines than the pageable height
        content.lines.count > pageable_height ||
          # Or if the content is a few long lines
          pageable_height * screen_width < Reline::Unicode.calculate_width(content, true)
      end

      def setup_pager(retain_content:)
        require 'shellwords'

        PAGE_COMMANDS.each do |pager_cmd|
          cmd = Shellwords.split(pager_cmd)
          next if cmd.empty?

          if cmd.first == 'less'
            cmd << '-R' unless cmd.include?('-R')
            cmd << '-X' if retain_content && !cmd.include?('-X')
          end

          begin
            io = ::IO.popen(cmd, 'w')
          rescue
            next
          end

          if $? && $?.pid == io.pid && $?.exited? # pager didn't work
            next
          end

          return io
        end

        nil
      end
    end

    class << self
      def page_content(content, **options)
        page(**options) do |io|
          io.puts content
        end
      end

      def page(retain_content: false)
        io = Pager::IO.new(retain_content: retain_content)
        begin
          yield io
        ensure
          io.close
        end
      # When user presses Ctrl-C, IRB would raise `IRB::Abort`
      # But since Pager is implemented by running paging commands like `less` in another process with `IO.popen`,
      # the `IRB::Abort` exception only interrupts IRB's execution but doesn't affect the pager
      # So to properly terminate the pager with Ctrl-C, we need to catch `IRB::Abort` and kill the pager process
      rescue Pager::Abort
      rescue IRB::Abort
        io.cleanup
        nil
      rescue Errno::EPIPE
      end
    end
  end
end
