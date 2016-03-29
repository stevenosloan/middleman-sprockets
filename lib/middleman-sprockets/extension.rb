require 'sprockets'
require 'middleman-core/contracts'
require 'middleman-core/sitemap/resource'

require_relative 'resource'
require_relative 'interface'

module Middleman
  module Sprockets
    class Extension < Extension
      attr_reader :environment,
                  :interface

      expose_to_config   sprockets: :environment
      expose_to_template sprockets: :environment

      option :supported_output_extensions, ['.css', '.js'], 'Output extensions sprockets should process'
      option :imported_asset_path,         'assets',        'Where under source imported assets should be placed.'
      option :expose_middleman_helpers,    false,           'Whether to expose middleman helpers to sprockets.'

      Contract ::Middleman::Application, Hash, Maybe[Proc] => Any
      def initialize app, options_hash={}, &block
        super

        @assets                  = Set.new
        @inline_asset_references = Set.new
        @environment             = ::Sprockets::Environment.new
        @interface               = Interface.new options, @environment

        use_sassc_if_available
      end

      Contract Any
      def after_configuration
        @environment.append_path((app.source_dir + app.config[:js_dir]).to_s)
        @environment.append_path((app.source_dir + app.config[:css_dir]).to_s)
        @environment.append_path(app.source_dir.to_s)

        append_paths_from_gems

        the_app = app
        the_env = environment

        @environment.context_class.send(:define_method, :app)  { the_app }
        @environment.context_class.send(:define_method, :data) { the_app.data }
        @environment.context_class.send(:define_method, :env)  { the_env }

        @environment.context_class.class_eval do
          def asset_path path, options={}
            # Handle people calling with the Middleman/Padrino asset path signature
            if path.is_a?(::Symbol) && !options.is_a?(::Hash)
              kind = path
              path = options
            else
              kind = {
                image: :images,
                font: :fonts,
                javascript: :js,
                stylesheet: :css
              }.fetch(options[:type], options[:type])
            end

            if File.extname(path).empty?
              path << { js: '.js', css: '.css' }.fetch(kind, '')
            end

            if app.extensions[:sprockets].check_asset(path)
              app.extensions[:sprockets].sprockets_asset_path(environment[path]).sub(/^\/?/, '/')
            else
              app.asset_path(kind, path)
            end
          end
        end

        expose_app_helpers_to_sprockets! if options[:expose_middleman_helpers]

        app.files.on_change :source, &method(:file_watcher)
      end

      Contract ResourceList => ResourceList
      def manipulate_resource_list resources
        sprockets_resources = ::Middleman::Util.instrument 'sprockets', name: 'manipulator.sprockets_resources' do
          resources.map do |resource|
            process_candidate_sprockets_resource(resource)
          end
        end

        linked_resources = ::Middleman::Util.instrument 'sprockets', name: 'manipulator.linked_resources' do
          @inline_asset_references.map do |path|
            asset = environment[path]
            generate_resource(sprockets_asset_path(asset), asset.filename, asset.logical_path)
          end
        end

        ::Middleman::Util.instrument 'sprockets', name: 'manipulator.ignore_resources' do
          if app.extensions[:sitemap_ignore].respond_to?(:manipulate_resource_list)
            app.extensions[:sitemap_ignore].manipulate_resource_list sprockets_resources + linked_resources
          else
            sprockets_resources + linked_resources
          end
        end
      end

      Contract ::Middleman::Sitemap::Resource => Bool
      def processible? r
        !r.is_a?(Resource) && interface.processible?(r.source_file)
      end

      Contract String => Bool
      def check_asset path
        if environment[path]
          @inline_asset_references << path
          true
        else
          false
        end
      end

      Contract ::Sprockets::Asset => String
      def sprockets_asset_path sprockets_asset
        File.join(options[:imported_asset_path], sprockets_asset.logical_path)
      end

      private

        # an overzealous method to ensure the sprockets cache
        # gets updated when middleman updates files
        #
        # return early if app is building, files shouldn't change in
        # that case and we don't want to remove the cache as it
        # gets hit during the resource manipulator
        #
        def file_watcher updated_files, removed_files
          return if app.build?

          if ((updated_files + removed_files).map(&:relative_path).map(&:to_s) &
                (@inline_asset_references + @assets.map(&:path)).to_a).empty?
            environment.cache = ::Sprockets::Cache::MemoryStore.new
          end

          if !(updated_files.map(&:relative_path).map(&:to_s) & @assets.map(&:path)).empty? ||
                !(removed_files.map(&:relative_path).map(&:to_s) & @assets.map(&:path)).empty?
            reset_sitemap!
          end
        end

        def reset_sitemap!
          @assets                  = Set.new
          @inline_asset_references = Set.new
          app.sitemap.rebuild_resource_list!(:'sprockets.asset_change')
          app.sitemap.ensure_resource_list_updated!
        end

        def expose_app_helpers_to_sprockets!
          @environment.context_class.class_eval do
            def current_resource
              logger.error "The use of `current_resource` in sprockets assets isn't currently implemented"
              nil
            end

            def mm_context
              @_mm_context ||= app.template_context_class.new(app)
            end

            def method_missing method, *args, &block
              if mm_context.respond_to?(method)
                return mm_context.send method, *args, &block
              end

              super
            end

            def respond_to? method, include_private=false
              super || mm_context.respond_to?(method, include_private)
            end
          end
        end

        Contract ::Middleman::Sitemap::Resource => Or[::Middleman::Sitemap::Resource, Resource]
        def process_candidate_sprockets_resource resource
          return resource unless processible?(resource)

          ::Middleman::Util.instrument 'sprockets', name: 'process_resource', resource: resource do
            sprockets_resource = generate_resource(resource.path, resource.source_file, resource.path)

            if sprockets_resource.respond_to?(:sprockets_asset) && !sprockets_resource.errored?
              @inline_asset_references.merge sprockets_resource.sprockets_asset.links
            end

            sprockets_resource
          end
        rescue => e
          logger.error("== Sprockets Debug: #{resource}")
          logger.error("== Sprockets Debug: #{sprockets_resource}") if defined?(sprockets_resource)
          raise e
        end

        Contract String, String, String => Or[Resource]
        def generate_resource path, source_file, sprockets_path
          ::Middleman::Util.instrument 'sprockets', name: 'generate_resource',
                                                    path: path,
                                                    sprockets_path: sprockets_path do
            resource = Resource.new(app.sitemap, path, source_file, sprockets_path, environment)
            @assets << resource
            resource
          end
        end

        def use_sassc_if_available
          if defined?(::SassC)
            require 'sprockets/sassc_processor'
            environment.register_transformer 'text/sass', 'text/css', ::Sprockets::SasscProcessor.new
            environment.register_transformer 'text/scss', 'text/css', ::Sprockets::ScsscProcessor.new

            logger.info '== Sprockets will render css with SassC'
          end
        rescue LoadError
          logger.info "== Sprockets will render css with ruby sass\n" \
                      '   consider using Sprockets 4.x to render with SassC'
        end

        # Backwards compatible means of finding all the latest gemspecs
        # available on the system
        #
        # @private
        # @return [Array] Array of latest Gem::Specification
        def rubygems_latest_specs
          # If newer Rubygems
          if ::Gem::Specification.respond_to? :latest_specs
            ::Gem::Specification.latest_specs(true)
          else
            ::Gem.source_index.latest_specs
          end
        end

        # Add any directories from gems with Rails-like paths to sprockets load path
        def append_paths_from_gems
          root_paths = rubygems_latest_specs.map(&:full_gem_path) << app.root
          base_paths = %w(assets app app/assets vendor vendor/assets lib lib/assets)
          asset_dirs = %w(javascripts js stylesheets css images img fonts)

          root_paths.product(base_paths.product(asset_dirs)).each do |root, (base, asset)|
            path = File.join(root, base, asset)
            environment.append_path(path) if File.directory?(path)
          end
        end
    end
  end
end
