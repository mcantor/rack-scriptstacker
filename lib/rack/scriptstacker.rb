require 'rack/scriptstacker/version'
require 'rack'

class ::Hash
  def recursive_merge other
    merger = proc do |key, v1, v2|
      Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : v2
    end
    self.merge(other, &merger)
  end
end

module Rack
  class ScriptStacker
    DEFAULT_CONFIG = {
      configure_static: true,
      stackers: {
        css: {
          template: '<link rel="stylesheet" type="text/css" href="%s" />',
          glob: '*.css',
          slot: 'CSS'
        },
        javascript: {
          template: '<script type="text/javascript" src="%s"></script>',
          glob: '*.js',
          slot: 'JAVASCRIPT'
        }
      }
    }

    def initialize app, config={}, &stack_spec
      @config = DEFAULT_CONFIG.recursive_merge config
      @path_specs = ScriptStackerUtils::SpecSolidifier.new.call stack_spec
      @runner = ScriptStackerUtils::Runner.new @config[:stackers]
      @app = @config[:configure_static] ? configure_static(app) : app
    end

    def call env
      response = @app.call env

      if response[1]['Content-Type'] != 'text/html'
        response
      else
        [
          response[0],
          response[1],
          @runner.replace_in_body(response[2], @path_specs)
        ]
      end
    end

    private

    def configure_static app
      Rack::Static.new app, {
        urls: @path_specs
          .values
          .reduce([]) { |memo, specs| memo + specs }
          .select { |spec| spec.paths_identical? }
          .map { |spec| spec.serve_path }
      }
    end
  end

  module ScriptStackerUtils
    class SpecSolidifier < BasicObject
      def initialize
        @specs = ::Hash.new { |hash, key|  hash[key] = [] }
      end

      def call stack_spec
        instance_eval &stack_spec
        @specs
      end

      def method_missing name, *args
        if args.size != 1
          raise ::ArgumentError.new(
            "Expected a path spec like 'static/css' => 'stylesheets', " +
            "but got #{args.inspect} instead."
          )
        end
        @specs[name].push ::Rack::ScriptStackerUtils::PathSpec.new(args[0])
      end
    end

    class PathSpec
      def initialize paths
        if paths.respond_to? :key
          # this is just for pretty method calls, eg.
          # css 'stylesheets' => 'static/css'
          @source_path, @serve_path = paths.to_a.flatten
        else
          # if only one path is given, use the same for both;
          # this is just like how Rack::Static works
          @source_path = @serve_path = paths
        end
      end

      def source_path
        normalize_end_slash @source_path
      end

      def serve_path
        normalize_end_slash normalize_begin_slash(@serve_path)
      end

      def paths_identical?
        # Paths are normalized differently, so this check isn't doable from
        # outside the instance; but we still want to know if they're basically
        # the same so we can easily configure Rack::Static to match.
        @source_path == @serve_path
      end

      private

      def normalize_end_slash path
        path.end_with?('/') ? path : path + '/'
      end

      def normalize_begin_slash path
        path.start_with?('/') ? path : '/' + path
      end
    end

    class Runner
      def initialize stacker_configs
        @stackers = stacker_configs.map do |name, config|
          [name, Stacker.new(config)]
        end.to_h
      end

      def replace_in_body body, path_specs
        path_specs.each do |name, specs|
          specs.each do |spec|
            @stackers[name].find_files spec.source_path, spec.serve_path
          end
        end

        body.map do |chunk|
          @stackers.values.reduce chunk do |memo, stacker|
            stacker.replace_slot memo
          end
        end
      end
    end

    class Stacker
      def initialize config
        @template = config[:template]
        @glob = config[:glob]
        @slot = config[:slot]
        @files = []
      end

      def find_files source_path, serve_path
        @files = @files + files_for(source_path).map do |filename|
          sprintf @template, serve_path + filename
        end
      end

      def replace_slot chunk
        chunk.gsub /^(\s*)#{slot}/ do
          indent = $1
          @files.map do |line|
            indent + line
          end.join "\n"
        end
      end

      private

      def slot
        "<!-- ScriptStacker: #{@slot} //-->"
      end

      def files_for source_path
        Dir[source_path + @glob]
          .map { |file| ::File.basename(file) }
      end
    end
  end
end
