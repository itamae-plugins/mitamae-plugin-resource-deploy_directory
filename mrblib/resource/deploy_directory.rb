# Ported from: https://github.com/chef/chef/blob/v12.13.37/lib/chef/resource/deploy.rb
module ::MItamae
  module Plugin
    module Resource
      # List of original attributes: https://github.com/chef/chef/blob/v12.13.37/lib/chef/resource/deploy.rb#L55-L85
      class DeployDirectory < ::MItamae::Resource::Base
        define_attribute :action, default: :deploy
        define_attribute :revision, type: String, default: 'HEAD'
        define_attribute :user, type: String
        define_attribute :group, type: String
        define_attribute :deploy_to, type: String
        define_attribute :keep_releases, type: Integer, default: 5
        define_attribute :rollback_on_error, type: [TrueClass, FalseClass], default: false
        define_attribute :before_migrate, type: Proc
        define_attribute :symlink_before_migrate, type: Hash, default: {}
        define_attribute :purge_before_symlink, type: Array, default: %w{log tmp/pids public/system}
        define_attribute :create_dirs_before_symlink, type: Array, default: %w{tmp public config}
        define_attribute :symlinks, type: Hash, default: { 'system' => 'public/system', 'pids' => 'tmp/pids', 'log' => 'log' }
        define_attribute :before_restart, type: Proc
        define_attribute :restart_command, type: [String, Array, Proc]
        define_attribute :after_restart, type: Proc

        define_attribute :migrate, type: [TrueClass, FalseClass], default: false
        define_attribute :before_symlink, type: Proc

        # Default values of following attributes are automatically set in #process_attributes
        define_attribute :current_path, type: String
        define_attribute :shared_path, type: String

        # deploy_directory's original attributes
        define_attribute :source, type: String

        self.available_actions = [:deploy]

        private

        def process_attributes
          unless @attributes.key?(:current_path)
            @attributes[:current_path] = File.join(@attributes.fetch(:deploy_to), 'current')
          end
          unless @attributes.key?(:shared_path)
            @attributes[:shared_path] = File.join(@attributes.fetch(:deploy_to), 'shared')
          end
          unless @attributes.key?(:depth)
            @attributes[:depth] = @attributes[:shallow_clone] ? 5 : nil
          end

          super
        end
      end
    end
  end
end
