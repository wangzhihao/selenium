require 'childprocess'
require 'java'
require 'rake-tasks/checks'

module Buck

  def self.download
    @@buck_bin ||= (
      if File.exist?('.nobuckcheck') && present?('buck')
        return ["buck"]
      end

      version = File.open('.buckversion').first.chomp
      cached_hash = File.open('.buckhash').first.chomp

      out = File.expand_path("~/.crazyfun/buck/#{version}/buck.pex")
      out_hash = File.exist?(out) ? Digest::MD5.file(out).hexdigest : nil

      if cached_hash == out_hash
        return ["python", out]
      end

      url = "https://github.com/SeleniumHQ/buck/releases/download/buck-release-#{version}/buck.pex"
      out_dir = File.dirname out
      FileUtils.mkdir_p(out_dir) unless File.exist?(out_dir)

      # Cut-and-pasted from rake-tasks/crazy_fun/mappings/java.rb. We duplicate the code here so
      # we can delete that file and have this continue working, but once we delete that file, we
      # should also stop using this version of ant and just use the ant bundled with jruby.
      dir = 'third_party/java/ant'
      Dir[File.join(dir, '*.jar')].each { |jar| require jar }
      # we set ANT_HOME to avoid JRuby trying to load its own Ant
      ENV['ANT_HOME'] = dir
      require "ant"

      ant.get('src' => url, 'dest' => out, 'verbose' => true)
      File.chmod(0755, out)
      ["python", out]
    )
  end

  def self.buck_cmd
    @@buck_cmd ||= (
      lambda { |command, args, &block|
        args ||= []
        buck = Buck::download

        buck.push(command)
        buck.push(*args)

        pump_class = Class.new(Java::java.io.OutputStream) {
          attr_writer :stream

          def initialize
            @output = ''
          end

          def write(b)
            if @stream
              @stream.write(b)
            end
            @output += b
          end

          def output
            @output
          end
        }

        err = ''
        proc = ChildProcess.build(*buck)
        proc.io.stdout = pump_class.new()
        proc.io.stderr = pump_class.new()
        if command == 'build' || command == 'publish' || command == 'test'
          proc.io.stderr.stream = $stdout
        end
        proc.start
        proc.wait

        if proc.exit_code != 0
          raise "Buck build failed"
        end

        block.call(proc.io.stdout.output) if block
      }
    )

    #block.call(output) if block
  end

  def self.enhance_task(task)
    class <<task
      def needed?
        true
      end

      attr_reader :out
      def out
        @out ||= Buck::find_buck_out(name)
      end
    end

    task
  end

  def self.find_buck_out(target)
    out = nil

    Buck::buck_cmd.call('targets', "--show-output #{target}") do |output|
      sections = output.chomp.split
      # Not all buck rules have an output file.
      if sections.size > 1
        out = output.chomp.split[-1]
      end
    end

    out
  end

end

def buck(*args, &block)
  case args[0]
    when String
      name = args[0].to_sym
      prereqs = []
    when Hash
      name = args[0].keys[0]
      pres = args[0][name]
      case pres
        when String
          prereqs = [pres]
        when Array
          prereqs = pres
        else
          raise "I have no idea what to do with this: #{pres.class.to_s}"
      end
    else
      raise "Unknown arg type: #{args[0].class.to_s}"
  end

  task = Rake::Task.task_defined?(name) ? Rake::Task[name] : Rake::Task.define_task(name)
  task.enhance prereqs do
    Buck::buck_cmd.call('build', name)
    block.call if block
  end

  Buck::enhance_task(task)
end

rule /\/\/.*:run/ => [ proc {|task_name| task_name[0..-5]} ] do |task|
  Buck::enhance_task(task)

  short = task.name[0..-5]

  task.enhance do
    # Figure out if this is an executable or a test target.
    Buck::buck_cmd.call('query', "#{short} --output-attributes buck.type") do |output|
      hash = JSON.parse(output)
      type = hash[short]['buck.type']
      if type =~ /.*_test/
        Buck::buck_cmd.call('test', short)
      else
        Buck::buck_cmd.call('run', "--verbose 5 #{short}")
      end
    end
  end
end

rule /\/\/.*/ do |task|
  # Task is a FileTask, but that's not what we need. Instead, just delegate down to buck in all
  # cases where the rule was not created by CrazyFun. Rules created by the "rule" method will
  # be a FileTask, whereas those created by CrazyFun are normal rake Tasks.

  if task.class == Rake::FileTask && !task.out
    task.enhance do
      Buck::buck_cmd.call('build', task.name)
    end

    Buck::enhance_task(task)
  end
end
