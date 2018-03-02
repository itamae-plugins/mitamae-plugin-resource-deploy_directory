# Ported from:
# https://github.com/chef/chef/blob/v12.13.37/lib/chef/provider/deploy.rb
# https://github.com/chef/chef/blob/v12.13.37/lib/chef/provider/deploy/revision.rb
module ::MItamae
  module Plugin
    module ResourceExecutor
      class DeployRevision < ::MItamae::ResourceExecutor::Base
        # Overriding https://github.com/itamae-kitchen/mitamae/blob/v1.5.6/mrblib/mitamae/resource_executor/base.rb#L31-L33,
        # and called at https://github.com/itamae-kitchen/mitamae/blob/v1.5.6/mrblib/mitamae/resource_executor/base.rb#L85
        # to reflect `desired` states which are not met in `current`.
        def apply
          if desired.deployed
            action_deploy
          else
            raise NotImplementedError, 'only deployed state is supported for now'
          end
        end

        private

        attr_reader :release_path, :previous_release_path

        # Overriding https://github.com/itamae-kitchen/mitamae/blob/v1.5.6/mrblib/mitamae/resource_executor/base.rb#L147-L149,
        # and called at https://github.com/itamae-kitchen/mitamae/blob/v1.5.6/mrblib/mitamae/resource_executor/base.rb#L67-L68
        # to map specified action (only :deploy here) to attributes to be modified. Attributes specified in recipes (:revision,
        # :repository, etc...) are already set to `desired`. So we don't need to set them manually.
        # https://github.com/itamae-kitchen/mitamae/blob/v1.5.6/mrblib/mitamae/resource_executor/base.rb#L142.
        #
        # Difference between `desired` and `current` are aimed to be changed in #apply.
        def set_desired_attributes(desired, action)
          case action
          when :deploy
            desired.deployed = true
          else
            raise NotImplementedError, "unhandled action: '#{action}'"
          end
        end

        # Overriding https://github.com/itamae-kitchen/mitamae/blob/v1.5.6/mrblib/mitamae/resource_executor/base.rb#L135-L137,
        # and called at https://github.com/itamae-kitchen/mitamae/blob/v1.5.6/mrblib/mitamae/resource_executor/base.rb#L70-L71
        # to map the current machine status to attributes. Probably similar to Chef's #load_current_resource.
        #
        # current_attributes which are the same as desired_attributes will NOT be touched in #apply.
        def set_current_attributes(current, action)
          load_current_resource
          case action
          when :deploy
            current.deployed = false
          else
            raise NotImplementedError, "unhandled action: '#{action}'"
          end
        end

        # https://github.com/chef/chef/blob/v12.13.37/lib/chef/provider/deploy.rb#L53-L57
        def load_current_resource
          # git-only support
          @scm_provider = GitProvider.new(
            repository: desired.repository,
            revision: desired.revision,
            destination: desired.destination,
            depth: desired.depth,
            enable_checkout: desired.enable_checkout,
            checkout_branch: desired.checkout_branch,
            additional_remotes: desired.additional_remotes,
            remote: desired.remote,
            log_prefix: log_prefix,
            runner: @runner, # MItamae's internal command runner
          )
          @release_path = File.join(desired.deploy_to, 'releases', @scm_provider.target_revision)
        end

        # The same as: https://github.com/chef/chef/blob/v12.13.37/lib/chef/provider/deploy.rb#L98-L112
        def action_deploy
          save_release_state
          if deployed?(release_path)
            if current_release?(release_path)
              MItamae.logger.debug("#{log_prefix} is the latest version")
            else
              rollback_to release_path
            end
          else
            with_rollback_on_error do
              deploy
            end
          end
        end

        def rollback_to(target_release_path)
          @release_path = target_release_path

          rp_index = all_releases.index(release_path)
          releases_to_nuke = all_releases[(rp_index + 1)..-1]

          rollback

          releases_to_nuke.each do |i|
            MItamae.logger.info "#{log_prefix} removing release: #{i}"
            @runner.run_command(['rm', '-rf', i])
            release_deleted(i)
          end
        end

        # https://github.com/chef/chef/blob/v12.13.37/lib/chef/provider/deploy.rb#L152-L168
        def deploy
          verify_directories_exist
          update_cached_repo
          enforce_ownership
          copy_cached_repo
          install_gems
          enforce_ownership
          callback(:before_migrate, desired.before_migrate)
          migrate
          callback(:before_symlink, desired.before_symlink)
          symlink
          callback(:before_restart, desired.before_restart)
          restart
          callback(:after_restart, desired.after_restart)
          cleanup!
          MItamae.logger.info "#{log_prefix} deployed to #{desired.deploy_to}"
        end

        def rollback
          MItamae.logger.info "#{log_prefix} rolling back to previous release #{release_path}"
          symlink
          MItamae.logger.info "#{log_prefix} restarting with previous release"
          restart
        end

        def callback(what, callback_code = nil)
          case callback_code
          when Proc
            MItamae.logger.info "#{log_prefix} running callback #{what}"
            recipe_eval(&callback_code)
          when String
            raise NotImplementedError, 'having String in callback is not supported'
          when nil
            # ignore this path for now
            # run_callback_from_file("#{release_path}/deploy/#{what}.rb")
          end
        end

        def recipe_eval(&block)
          recipe = MItamae::Recipe.new(@resource.recipe.path, @resource.recipe).tap do |r|
            variables = {
              release_path: release_path,
            }
            MItamae::RecipeContext.new(r, variables).instance_exec(&block)
          end
          MItamae::RecipeExecutor.new(@runner).execute([recipe])
        end

        def migrate
          run_symlinks_before_migrate

          if desired.migrate
            enforce_ownership

            raise NotImplementedError, 'migrate is not supported yet'
          end
        end

        def symlink
          purge_tempfiles_from_current_release
          link_tempfiles_to_current_release
          link_current_release_to_production
          MItamae.logger.info "#{log_prefix} updated symlinks"
        end

        def restart
          if restart_cmd = desired.restart_command
            if restart_cmd.kind_of?(Proc)
              MItamae.logger.info("#{log_prefix} restarting app with embedded recipe")
              recipe_eval(&restart_cmd)
            else
              MItamae.logger.info("#{log_prefix} restarting app")
              @runner.run_command(restart_cmd, { cwd: desired.current_path })
            end
          end
        end

        def cleanup!
          release_created(release_path)

          chop = -1 - desired.keep_releases
          all_releases[0..chop].each do |old_release|
            MItamae.logger.info "#{log_prefix} removing old release #{old_release}"
            @runner.run_command(['rm', '-rf', old_release])
            release_deleted(old_release)
          end
        end

        def install_gems
          return unless ::File.exist?("#{release_path}/gems.yml")
          raise NotImplementedError, "Do I need to support https://gems.github.com in 2018?"
        end

        def verify_directories_exist
          create_dir_unless_exists(desired.deploy_to)
          create_dir_unless_exists(desired.shared_path)
        end

        def create_dir_unless_exists(dir)
          if File.directory?(dir)
            MItamae.logger.debug "#{log_prefix} Not creating #{dir} because it already exists"
            return
          end

          @runner.run_command(['mkdir', '-p', dir])
          MItamae.logger.debug "#{log_prefix} created directory #{dir}"
          if desired.user
            @runner.run_command(['chown', desired.user, dir])
            MItamae.logger.debug("#{log_prefix} set user to #{desired.user} for #{dir}")
          end
          if desired.group
            @runner.run_command(['chown', ":#{desired.group}", dir])
            MItamae.logger.debug("#{log_prefix} set group to #{desired.group} for #{dir}")
          end
        end

        def with_rollback_on_error
          yield
        rescue ::Exception => e
          if desired.rollback_on_error
            MItamae.logger.warn "Error on deploying #{release_path}: #{e.message}"
            failed_release = release_path

            if previous_release_path
              @release_path = previous_release_path
              rollback
            end
            MItamae.logger.info "Removing failed deploy #{failed_release}"
            @runner.run_command(['rm', '-rf', failed_release])
            release_deleted(failed_release)
          end

          raise
        end

        def log_prefix
          "#{@resource.resource_type}[#{@resource.resource_name}]"
        end

        def update_cached_repo
          # no svn_force_export support
          run_scm_sync
        end

        def run_scm_sync
          @scm_provider.action_sync
        end

        # TODO: Let gromnitsky/mruby-fileutils-simple have some missing options and use FileUtils in it.
        # Currently using `@runner.run_command` to bypass user change because `desired.user` is differently purposed in this resource.
        def copy_cached_repo
          target_dir_path = File.join(desired.deploy_to, 'releases')
          @runner.run_command(['rm', '-rf', release_path]) if ::File.exist?(release_path)
          @runner.run_command(['mkdir', '-p', target_dir_path])
          @runner.run_command(['cp', '-rp', ::File.join(desired.destination, '.'), release_path])
          MItamae.logger.info "#{log_prefix} copied the cached checkout to #{release_path}"
        end

        def enforce_ownership
          @runner.run_command(['chown', '-Rf', "#{desired.user}:#{desired.group}", desired.deploy_to])
          MItamae.logger.info("#{log_prefix} set user to #{desired.user}") if desired.user
          MItamae.logger.info("#{log_prefix} set group to #{desired.group}") if desired.group
        end

        def link_current_release_to_production
          @runner.run_command(['rm', '-f', desired.current_path])
          @runner.run_command(['ln', '-sf', release_path, desired.current_path])
          MItamae.logger.info "#{log_prefix} linked release #{release_path} into production at #{desired.current_path}"
          enforce_ownership
        end

        def run_symlinks_before_migrate
          desired.symlink_before_migrate.each do |src, dest|
            @runner.run_command(['ln', '-sf', File.join(desired.shared_path, src), File.join(release_path, dest)])
          end
          MItamae.logger.info "#{log_prefix} made pre-migration symlinks"
        end

        def link_tempfiles_to_current_release
          dirs_info = desired.create_dirs_before_symlink.join(',')
          desired.create_dirs_before_symlink.each do |dir|
            create_dir_unless_exists(File.join(release_path, dir))
          end
          MItamae.logger.info("#{log_prefix} created directories before symlinking: #{dirs_info}")

          links_info = desired.symlinks.map { |src, dst| "#{src} => #{dst}" }.join(", ")
          desired.symlinks.each do |src, dest|
            @runner.run_command(['ln', '-sf', File.join(desired.shared_path, src), File.join(release_path, dest)])
          end
          MItamae.logger.info("#{log_prefix} linked shared paths into current release: #{links_info}")
          run_symlinks_before_migrate
          enforce_ownership
        end

        def purge_tempfiles_from_current_release
          log_info = desired.purge_before_symlink.join(', ')
          desired.purge_before_symlink.each { |dir| @runner.run_command(['rm', '-rf', File.join(release_path, dir)]) }
          MItamae.logger.info("#{log_prefix} purged directories in checkout #{log_info}")
        end

        def save_release_state
          if ::File.exists?(desired.current_path)
            release = ::File.readlink(desired.current_path)
            @previous_release_path = release if ::File.exists?(release)
          end
        end

        def deployed?(release)
          all_releases.include?(release)
        end

        def current_release?(release)
          @previous_release_path == release
        end

        # Above code is in Chef::Provider::Deploy. Following code is in Chef::Provider::Deploy::Revision

        def all_releases
          sorted_releases
        end

        def release_created(release)
          sorted_releases { |r| r.delete(release); r << release }
        end

        def release_deleted(release)
          sorted_releases { |r| r.delete(release) }
        end

        def sorted_releases
          cache = load_cache
          if block_given?
            yield cache
            save_cache(cache)
          end
          cache
        end

        def sorted_releases_from_filesystem
          Dir.glob(escape_glob_dir(desired.deploy_to) + '/releases/*').sort_by do |d|
            # Workaround for missing File.ctime
            Integer(@runner.run_command(['stat', '--format=%Y', d]).stdout.rstrip)
          end
        end

        # modified not to use file cache
        def load_cache
          @releases_cache ||= nil # No `defined?` in mruby
          if @releases_cache
            @releases_cache
          else
            @releases_cache = sorted_releases_from_filesystem
          end
        end

        # modified not to use file cache
        def save_cache(cache)
          @releases_cache = cache
        end

        # https://github.com/chef/chef/blob/v12.13.37/chef-config/lib/chef-config/path_helper.rb#L166-L169
        def escape_glob_dir(path)
          # Skipping Pathname#cleanpath because mitamae doesn't install it for now
          #path = Pathname.new(join(*parts)).cleanpath.to_s
          path.gsub(/[\\\{\}\[\]\*\?]/) { |x| "\\" + x }
        end

        # :sync, :checkout only implementation of https://github.com/chef/chef/blob/v12.13.37/lib/chef/provider/git.rb
        class GitProvider
          def initialize(options = {})
            @repository = options.fetch(:repository)
            @revision = options.fetch(:revision)
            @destination = options.fetch(:destination)
            @depth = options.fetch(:depth)
            @enable_checkout = options.fetch(:enable_checkout)
            @checkout_branch = options.fetch(:checkout_branch)
            @additional_remotes = options.fetch(:additional_remotes)
            @remote = options.fetch(:remote)
            @log_prefix = options.fetch(:log_prefix)
            @runner = options.fetch(:runner)
          end

          def action_checkout
            if target_dir_non_existent_or_empty?
              clone
              if @enable_checkout
                checkout
              end
              enable_submodules
              add_remotes
            else
              MItamae.logger.debug "#{@log_prefix} checkout destination #{@destination} already exists or is a non-empty directory"
            end
          end

          def action_sync
            if existing_git_clone?
              MItamae.logger.debug "#{@log_prefix} current revision: #{ 'TODO' } target revision: #{ 'TODO' }"
              unless current_revision_matches_target_revision?
                fetch_updates
                enable_submodules
                MItamae.logger.info "#{@log_prefix} updated to revision #{target_revision}"
              end
              add_remotes
            else
              action_checkout
            end
          end

          def target_revision
            @target_revision ||= begin
              if sha_hash?(@revision)
                @target_revision = @revision
              else
                @target_revision = remote_resolve_reference
              end
            end
          end

          private

          def existing_git_clone?
            ::File.exist?(::File.join(@destination, '.git'))
          end

          def target_dir_non_existent_or_empty?
            !::File.exist?(@destination) || Dir.entries(@destination).sort == ['.', '..']
          end

          def add_remotes
            if @additional_remotes.length > 0
              @additional_remotes.each_pair do |remote_name, remote_url|
                MItamae.logger.info "#{@log_prefix} adding git remote #{remote_name} = #{remote_url}"
                setup_remote_tracking_branches(remote_name, remote_url)
              end
            end
          end

          def clone
            # no remote change support

            clone_cmd = ['clone']
            clone_cmd << "--depth #{@depth}" if @depth
            clone_cmd << "--no-single-branch" if @depth
            clone_cmd << "\"#{@repository}\""
            clone_cmd << "\"#{@destination}\""

            MItamae.logger.info "#{@log_prefix} cloning repo #{@repository} to #{@destination}"
            git clone_cmd
          end

          def checkout
            sha_ref = target_revision

            # checkout into a local branch rather than a detached HEAD
            git('-C', @destination, 'branch', '-f', @checkout_branch, sha_ref)
            git('-C', @destination, 'checkout', @checkout_branch)
            MItamae.logger.info "#{@log_prefix} checked out branch: #{@revision} onto: #{@checkout_branch} reference: #{sha_ref}"
          end

          def enable_submodules
            if @enable_submodules
              MItamae.logger.info "#{@log_prefix} synchronizing git submodules"
              git('-C', @destination, 'submodule', 'sync')
              MItamae.logger.info "#{@log_prefix} enabling git submodules"
              # the --recursive flag means we require git 1.6.5+ now, see CHEF-1827
              git('-C', @destination, 'submodule', 'update', '--init', '--recursive')
            end
          end

          def fetch_updates
            setup_remote_tracking_branches(@remote, @repository)
            # since we're in a local branch already, just reset to specified revision rather than merge
            MItamae.logger.debug "Fetching updates from #{@remote} and resetting to revision #{target_revision}"
            git('-C', @destination, "fetch", @remote)
            git('-C', @destination, "fetch", @remote, "--tags")
            git('-C', @destination, "reset", "--hard", target_revision)
          end

          def setup_remote_tracking_branches(remote_name, remote_url)
            MItamae.logger.debug "#{@log_prefix} configuring remote tracking branches for repository #{remote_url} " + "at remote #{remote_name}"
            check_remote_command = ["config", "--get", "remote.#{remote_name}.url"]
            remote_status = git('-C', @destination, check_remote_command)
            case remote_status.exit_status
            when 0, 2
              # * Status 0 means that we already have a remote with this name, so we should update the url
              #   if it doesn't match the url we want.
              # * Status 2 means that we have multiple urls assigned to the same remote (not a good idea)
              #   which we can fix by replacing them all with our target url (hence the --replace-all option)

              if multiple_remotes?(remote_status) || !remote_matches?(remote_url, remote_status)
                git('-C', @destination, 'config', '--replace-all', "remote.#{remote_name}.url", remote_url)
              end
            when 1
              git('-C', @destination, 'remote', 'add', remote_name, remote_url)
            end
          end

          def multiple_remotes?(check_remote_command_result)
            check_remote_command_result.exit_status == 2
          end

          def remote_matches?(remote_url, check_remote_command_result)
            check_remote_command_result.stdout.strip.eql?(remote_url)
          end

          def current_revision_matches_target_revision?
            # removing `to_i(16)` to work around mruby error: too big for integer (ArgumentError)
            #(!@revision.nil?) && (target_revision.strip.to_i(16) == @revision.strip.to_i(16))
            (!@revision.nil?) && (target_revision.strip == @revision.strip)
          end

          # https://github.com/chef/chef/blob/v12.13.37/lib/chef/provider/git.rb#L237-L259
          def remote_resolve_reference
            MItamae.logger.debug("#{@log_prefix} resolving remote reference")
            # The sha pointed to by an annotated tag is identified by the
            # '^{}' suffix appended to the tag. In order to resolve
            # annotated tags, we have to search for "revision*" and
            # post-process. Special handling for 'HEAD' to ignore a tag
            # named 'HEAD'.
            @resolved_reference = git_ls_remote(rev_search_pattern)
            refs = @resolved_reference.split("\n").map { |line| line.split("\t") }
            # First try for ^{} indicating the commit pointed to by an
            # annotated tag.
            # It is possible for a user to create a tag named 'HEAD'.
            # Using such a degenerate annotated tag would be very
            # confusing. We avoid the issue by disallowing the use of
            # annotated tags named 'HEAD'.
            if rev_search_pattern != 'HEAD'
              found = find_revision(refs, @revision, '^{}')
            else
              found = refs_search(refs, 'HEAD')
            end
            found = find_revision(refs, @revision) if found.empty?
            found.size == 1 ? found.first[0] : nil
          end

          def find_revision(refs, revision, suffix = '')
            found = refs_search(refs, rev_match_pattern('refs/tags/', revision) + suffix)
            found = refs_search(refs, rev_match_pattern('refs/heads/', revision) + suffix) if found.empty?
            found = refs_search(refs, revision + suffix) if found.empty?
            found
          end

          def rev_match_pattern(prefix, revision)
            if revision.start_with?(prefix)
              revision
            else
              prefix + revision
            end
          end

          def rev_search_pattern
            if ['', 'HEAD'].include? @revision
              'HEAD'
            else
              @revision + '*'
            end
          end

          def git_ls_remote(rev_pattern)
            git('ls-remote', "\"#{@repository}\"", "\"#{rev_pattern}\"").stdout
          end

          def refs_search(refs, pattern)
            refs.find_all { |m| m[1] == pattern }
          end

          def git(*args)
            git_command = ['git', args].compact.join(' ')
            @runner.run_command(git_command)
          end

          def sha_hash?(string)
            string =~ /\A[0-9a-f]{40}\z/
          end
        end
      end
    end
  end
end
