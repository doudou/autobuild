require 'fileutils'
require 'autobuild/subcommand'
require 'autobuild/importer'
require 'utilrb/kernel/options'

module Autobuild
    class Git < Importer
        class << self
            # Sets the default alternates path used by all Git importers
            #
            # Setting it explicitly overrides any value we get from the
            # AUTOBUILD_CACHE_DIR and AUTOBUILD_GIT_CACHE_DIR environment
            # variables.
            #
            # @see default_alternates
            attr_writer :default_alternates

            # A default list of repositories that should be used as reference
            # repositories for all Git importers
            #
            # It is initialized (by order of priority) using the
            # AUTOBUILD_GIT_CACHE_DIR and AUTOBUILD_CACHE_DIR environment
            # variables
            #
            # @return [Array]
            # @see default_alternates=, Git#alternates
            def default_alternates
                if @default_alternates then @default_alternates
                elsif cache_dir = ENV['AUTOBUILD_GIT_CACHE_DIR']
                    @default_alternates = cache_dir.split(':').map { |path| File.expand_path(path) }
                elsif cache_dir = ENV['AUTOBUILD_CACHE_DIR']
                    @default_alternates = cache_dir.split(':').map { |path| File.join(File.expand_path(path), 'git', '%s') }
                else Array.new
                end
            end
        end

        # Creates an importer which tracks the given repository
        # and branch. +source+ is [repository, branch]
        #
        # This importer uses the 'git' tool to perform the
        # import. It defaults to 'git' and can be configured by
        # doing 
	#   Autobuild.programs['git'] = 'my_git_tool'
        def initialize(repository, branch = nil, options = {})
            @alternates = Git.default_alternates.dup
            @git_dir_cache = Array.new

            if branch.respond_to?(:to_hash)
                options = branch.to_hash
                branch = nil
            end

            if branch
                Autobuild.warn "the git importer now expects you to provide the branch as a named option"
                Autobuild.warn "this form is deprecated:"
                Autobuild.warn "   Autobuild.git 'git://gitorious.org/rock/buildconf.git', 'master'"
                Autobuild.warn "and should be replaced by"
                Autobuild.warn "   Autobuild.git 'git://gitorious.org/rock/buildconf.git', :branch => 'master'"
            end

            gitopts, common = Kernel.filter_options options,
                push_to: nil,
                branch: nil,
                tag: nil,
                commit: nil,
                with_submodules: false
            if gitopts[:branch] && branch
                raise ConfigException, "git branch specified with both the option hash and the explicit parameter"
            end

            sourceopts, common = Kernel.filter_options common,
                :repository_id, :source_id

            super(common)

            @push_to = gitopts[:push_to]
            @with_submodules = gitopts[:with_submodules]
            branch = gitopts[:branch] || branch
            tag    = gitopts[:tag]
            commit = gitopts[:commit]

            @branch = branch || 'master'
            @tag    = tag
            @commit = commit
            @remote_name = 'autobuild'
            relocate(repository, sourceopts)
        end

        # The name of the remote that should be set up by the importer
        #
        # Defaults to 'autobuild'
        attr_accessor :remote_name

        # The remote repository URL.
        #
        # See also #push_to
        attr_accessor :repository

        # If set, this URL will be listed as a pushurl for the tracked branch.
        # It makes it possible to have a read-only URL for fetching and specify
        # a push URL for people that have commit rights
        #
        # #repository is always used for read-only operations
        attr_accessor :push_to

        # The remote branch to which we should push
        #
        # Defaults to #branch
        attr_writer :remote_branch

        # Set to true if checkout should be done with submodules
        #
        # Defaults to #false
        attr_writer :with_submodules

        # The branch this importer is tracking
        #
        # If set, both commit and tag have to be nil.
        attr_accessor :branch

        # The branch that should be used on the local clone
        #
        # If not set, it defaults to #branch
        attr_writer :local_branch

        # A list of local (same-host) repositories that will be used instead of
        # the remote one when possible. It has one major issue (see below), so
        # use at your own risk.
        #
        # The paths must point to the git directory, so either the .git
        # directory in a checked out git repository, or the repository itself in
        # a bare repository.
        #
        # A default reference repository can be given through the
        # AUTOBUILD_GIT_CACHE environment variable.
        #
        # Note that it has the major caveat that if objects disappear from the
        # reference repository, the current one will be broken. See the git
        # documentation for more information.
        #
        # @return [Array<String>]
        attr_accessor :alternates

        # The branch that should be used on the local clone
        #
        # Defaults to #branch
        def local_branch
            @local_branch || branch
        end

        # The remote branch to which we should push
        #
        # Defaults to #branch
        def remote_branch
            @remote_branch || branch
        end

        # The tag we are pointing to. It is a tag name.
        #
        # If set, both branch and commit have to be nil.
        attr_accessor :tag

        # The commit we are pointing to. It is a commit ID.
        #
        # If set, both branch and tag have to be nil.
        attr_accessor :commit

        # True if it is allowed to merge remote updates automatically. If false
        # (the default), the import will fail if the updates do not resolve as
        # a fast-forward
        def merge?; !!@merge end

        #Return true if the git checkout should be done with submodules
        #detaul it false
        def with_submodules?; !!@with_submodules end

        # Set the merge flag. See #merge?
        def merge=(flag); @merge = flag end

        # Raises ConfigException if the current directory is not a git
        # repository
        def validate_importdir(package)
            return git_dir(package, true)
        end

        # Resolves the git directory associated with path, and tells whether it
        # is a bare repository or not
        #
        # @param [String] path the path from which we should resolve
        # @return [(String,Symbol),nil] either the path to the git folder and
        #  :bare or :normal, or nil if path is not a git repository.
        def self.resolve_git_dir(path)
            dir = File.join(path, '.git')
            if !File.exists?(dir)
                dir = path
            end

            result = `#{Autobuild.tool(:git)} --git-dir="#{dir}" rev-parse --is-bare-repository 2>&1`
            if $?.success?
                if result.strip == "true"
                    return dir, :bare
                else return dir, :normal
                end
            end
        end

        def git_dir(package, require_working_copy)
            if @git_dir_cache[0] == package.importdir
                dir, style = *@git_dir_cache[1, 2]
            else
                dir, style = Git.resolve_git_dir(package.importdir)
            end

            @git_dir_cache = [package.importdir, dir, style]
            self.class.validate_git_dir(package, require_working_copy, dir, style)
            dir
        end

        def self.git_dir(package, require_working_copy)
            dir, style = Git.resolve_git_dir(package.importdir)
            validate_git_dir(package, require_working_copy, dir, style)
            dir
        end

        def self.validate_git_dir(package, require_working_copy, dir, style)
            if !style
                raise ConfigException.new(package, 'import'), "while importing #{package.name}, #{package.importdir} does not point to a git repository"
            elsif require_working_copy && (style == :bare)
                raise ConfigException.new(package, 'import'), "while importing #{package.name}, #{package.importdir} points to a bare git repository but a working copy was required"
            end
        end

        # Computes the merge status for this package between two existing tags
        # Raises if a tag is unknown
        def delta_between_tags(package, from_tag, to_tag)
            pkg_tags = tags(package)
            if not pkg_tags.has_key?(from_tag)
                raise ArgumentError, "tag '#{from_tag}' is unknown to #{package.name} -- known tags are: #{pkg_tags.keys}"
            end
            if not pkg_tags.has_key?(to_tag)
                raise ArgumentError, "tag '#{to_tag}' is unknown to #{package.name} -- known tags are: #{pkg_tags.keys}"
            end

            from_commit = pkg_tags[from_tag]
            to_commit = pkg_tags[to_tag]

            merge_status(package, to_commit, from_commit)
        end

        # Retrieve the tags of this packages as a hash mapping to the commit id
        def tags(package)
            run_git_bare(package, 'fetch', '--tags')
            tag_list = run_git_bare(package, 'show-ref', '--tags').map(&:strip)
            tags = Hash.new
            tag_list.each do |entry|
                commit_to_tag = entry.split(" ")
                tags[commit_to_tag[1].sub("refs/tags/","")] = commit_to_tag[0]
            end
            tags
        end

        def run_git(package, *args)
            self.class.run_git(package, *args)
        end

        def self.run_git(package, *args)
            options = Hash.new
            if args.last.kind_of?(Hash)
                options = args.pop
            end

            working_directory = File.dirname(git_dir(package, true))
            package.run(:import, Autobuild.tool(:git), *args,
                        Hash[working_directory: working_directory].merge(options))
        end

        def run_git_bare(package, *args)
            self.class.run_git_bare(package, *args)
        end

        def self.run_git_bare(package, *args)
            package.run(:import, Autobuild.tool(:git), '--git-dir', git_dir(package, false), *args)
        end

        # Updates the git repository's configuration for the target remote
        def update_remotes_configuration(package)
            run_git_bare(package, 'config', '--replace-all', "remote.#{remote_name}.url", repository)
            run_git_bare(package, 'config', '--replace-all', "remote.#{remote_name}.pushurl", push_to || repository)
            run_git_bare(package, 'config', '--replace-all', "remote.#{remote_name}.fetch",  "+refs/heads/*:refs/remotes/#{remote_name}/*")

            if remote_branch && local_branch
                run_git_bare(package, 'config', '--replace-all', "remote.#{remote_name}.push",  "refs/heads/#{local_branch}:refs/heads/#{remote_branch}")
            else
                run_git_bare(package, 'config', '--replace-all', "remote.#{remote_name}.push",  "refs/heads/*:refs/heads/*")
            end

            if local_branch
                run_git_bare(package, 'config', '--replace-all', "branch.#{local_branch}.remote",  remote_name)
                run_git_bare(package, 'config', '--replace-all', "branch.#{local_branch}.merge", "refs/heads/#{local_branch}")
            end
        end

        # Fetches updates from the remote repository. Returns the remote commit
        # ID on success, nil on failure. Expects the current directory to be the
        # package's source directory.
        def fetch_remote(package)
            validate_importdir(package)
            git_dir = git_dir(package, false)

            # If we are checking out a specific commit, we don't know which
            # branch to refer to in git fetch. So, we have to set up the
            # remotes and call git fetch directly (so that all branches get
            # fetch)
            #
            # Otherwise, do git fetch now
            #
            # Doing it now is better as it makes sure that we replace the
            # configuration parameters only if the repository and branch are
            # OK (i.e. we keep old working configuration instead)
            refspec = [branch || tag].compact
            run_git_bare(package, 'fetch', '--tags', repository, *refspec, retry: true)

            update_remotes_configuration(package)

            # Now get the actual commit ID from the FETCH_HEAD file, and
            # return it
            commit_id = if File.readable?( File.join(git_dir, 'FETCH_HEAD') )
                fetch_commit = File.readlines( File.join(git_dir, 'FETCH_HEAD') ).
                    delete_if { |l| l =~ /not-for-merge/ }
                if !fetch_commit.empty?
                    fetch_commit.first.split(/\s+/).first
                end
            end

            # Update the remote tag if needs be
            if branch && commit_id
                run_git_bare(package, 'update-ref', "-m", "updated by autobuild", "refs/remotes/#{remote_name}/#{remote_branch}", commit_id)
            end

            commit_id
        end

        def self.has_uncommitted_changes?(package, with_untracked_files = false)
            status = run_git(package, 'status', '--porcelain').map(&:strip)
            if with_untracked_files
                !status.empty?
            else
                status.any? { |l| l[0, 2] !~ /^\?\?|^  / }
            end
        end

        # Returns the commit ID of what we should consider being the remote
        # commit
        #
        # @param [Package] package
        # @param [Boolean] only_local if true, no remote access should be
        #   performed, in which case the current known state of the remote will be
        #   used. If false, we access the remote repository to fetch the actual
        #   commit ID
        # @return [String] the commit ID as a string
        def current_remote_commit(package, only_local = false)
            if only_local
                begin
                    run_git_bare(package, 'show-ref', '-s', "refs/remotes/#{remote_name}/#{remote_branch}").first.strip
                rescue SubcommandFailed
                    raise PackageException.new(package, "import"), "cannot resolve remote HEAD #{remote_name}/#{remote_branch}"
                end
            else	
                begin fetch_remote(package)
                rescue Exception => e
                    return fallback(e, package, :status, package, only_local)
                end
            end
        end


        # Returns a Importer::Status object that represents the status of this
        # package w.r.t. the root repository
        def status(package, only_local = false)
            validate_importdir(package)
            remote_commit = current_remote_commit(package, only_local)
            status = merge_status(package, remote_commit)
            status.uncommitted_code = self.class.has_uncommitted_changes?(package)
            status
        end

        def has_branch?(package, branch_name)
            run_git_bare(package, 'show-ref', '-q', '--verify', "refs/heads/#{branch_name}")
            true
        rescue SubcommandFailed => e
            if e.status == 1
                false
            else raise
            end
        end

        def has_local_branch?(package)
            has_branch?(package, local_branch)
        end

        def detached_head?(package)
            run_git_bare(package, 'symbolic-ref', 'HEAD', '-q')
            true
        rescue SubcommandFailed => e
            if e.status == 1
                false
            else raise
            end
        end

        def current_branch(package)
            run_git_bare(package, 'symbolic-ref', 'HEAD', '-q').first.strip
        rescue SubcommandFailed => e
            if e.status == 1
                return
            else raise
            end
        end

        # Checks if the current branch is the target branch. Expects that the
        # current directory is the package's directory
        def on_target_branch?(package)
            if current_branch = self.current_branch(package)
                current_branch == "refs/heads/#{local_branch}"
            end
        end

        class Status < Importer::Status
            attr_reader :fetch_commit
            attr_reader :head_commit
            attr_reader :common_commit

            def initialize(package, status, remote_commit, local_commit, common_commit)
                super()
                @status        = status
                @fetch_commit  = fetch_commit
                @head_commit   = head_commit
                @common_commit = common_commit

                if remote_commit != common_commit
                    @remote_commits = log(package, common_commit, remote_commit)
                end
                if local_commit != common_commit
                    @local_commits = log(package, common_commit, local_commit)
                end
            end

            def needs_update?
                status == Status::NEEDS_MERGE || status == Status::SIMPLE_UPDATE
            end

            def log(package, from, to)
                log = package.importer.run_git_bare(package, 'log', '--encoding=UTF-8', "--pretty=format:%h %cr %cn %s", "#{from}..#{to}")
                log.map do |line|
                    line.strip.encode
                end
            end
        end

        def rev_parse(package, name)
            run_git_bare(package, 'rev-parse', name).first
        rescue Autobuild::SubcommandFailed
            raise PackageException.new(package, 'import'), "failed to resolve #{name}. Are you sure this commit, branch or tag exists ?"
        end

        def show(package, commit, path)
            run_git_bare(package, 'show', "#{commit}:#{path}").join("\n")
        rescue Autobuild::SubcommandFailed
            raise PackageException.new(package, 'import'), "failed to either resolve commit #{commit} or file #{path}"
        end

        # Computes the update status to update a branch whose tip is at
        # reference_commit (which can be a symbolic reference) using the
        # fetch_commit commit
        #
        # I.e. this compute what happens if one would do
        #
        #   git checkout reference_commit
        #   git merge fetch_commit
        #
        def merge_status(package, fetch_commit, reference_commit = "HEAD")
            begin
                common_commit = run_git_bare(package, 'merge-base', reference_commit, fetch_commit).first.strip
            rescue Exception
                raise PackageException.new(package, 'import'), "failed to find the merge-base between #{reference_commit} and #{fetch_commit}. Are you sure these commits exist ?"
            end
            remote_commit = rev_parse(package, fetch_commit)
            head_commit   = rev_parse(package, reference_commit)

            status = if common_commit != remote_commit
                         if common_commit == head_commit
                             Status::SIMPLE_UPDATE
                         else
                             Status::NEEDS_MERGE
                         end
                     else
                         if common_commit == head_commit
                             Status::UP_TO_DATE
                         else
                             Status::ADVANCED
                         end
                     end

            Status.new(package, status, fetch_commit, head_commit, common_commit)
        end

        # Updates the git alternates file in the already checked out package to
        # match {#alternates}
        #
        # @param [Package] package the already checked-out package
        # @return [void]
        def update_alternates(package)
            alternates_path = File.join(git_dir(package, false), 'objects', 'info', 'alternates')
            current_alternates =
                if File.file?(alternates_path)
                    File.readlines(alternates_path).map(&:strip).find_all { |l| !l.empty? }
                else Array.new
                end

            alternates = each_alternate_path(package).map do |path|
                File.join(path, 'objects')
            end

            if current_alternates.sort != alternates.sort
                # Warn that something is fishy, but assume that the user knows
                # what he is doing
                package.warn "%s: the list of git alternates listed in the repository differs from the one set up in autobuild."
                package.warn "%s: I will update, but that is dangerous"
                package.warn "%s: using git alternates is for advanced users only, who know git very well."
                package.warn "%s: Don't complain if something breaks"
            end
            if alternates.empty?
                FileUtils.rm_f alternates_path
            else
                File.open(alternates_path, 'w') do |io|
                    io.write alternates.join("\n")
                end
            end
        end

        def commit_pinning(package, target_commit)
            status_to_head = merge_status(package, target_commit, "HEAD").status

            if status_to_head != Status::SIMPLE_UPDATE && status_to_head != Status::UP_TO_DATE
                raise PackageException.new(package, 'import'), "checking out the specified commit #{target_commit} would be a non-simple operation (i.e. the current state of the repository is not a linear relationship with the specified commit), do it manually"
            elsif !has_local_branch?(package)
                run_git(package, 'checkout', '-b', local_branch, target_commit)
            else
                status_to_branch = merge_status(package, target_commit, local_branch)
                if status_to_branch.status == Status::UP_TO_DATE # Checkout the branch
                    run_git(package, 'checkout', local_branch)
                else
                    package.message "  checking out specific commit %s for %s. This will create a detached HEAD." % [target_commit.to_s, package.name]
                    run_git(package, 'checkout', target_commit)
                end
            end
        end

        def update(package,only_local = false)
            validate_importdir(package)
            # This is really really a hack to workaround how broken the
            # importdir thing is
            if package.importdir == package.srcdir
                update_alternates(package)
            end

            fetch_commit = current_remote_commit(package, only_local)

            # If we are tracking a commit/tag, just check it out and return
            if commit || tag
                commit_pinning(package, commit || tag)
            elsif !has_local_branch?(package)
                package.message "%%s: checking out branch %s" % [local_branch]
                run_git(package, 'checkout', '-b', local_branch, fetch_commit)
            else
                if !on_target_branch?(package)
                    package.message "%%s: switching to branch %s" % [local_branch]
                    run_git(package, 'checkout', local_branch)
                end
                status = merge_status(package, fetch_commit)
                if status.needs_update?
                    if !merge? && status.status == Status::NEEDS_MERGE
                        raise PackageException.new(package, 'import'), "the local branch '#{local_branch}' and the remote branch #{branch} of #{package.name} have diverged, and I therefore refuse to update automatically. Go into #{package.importdir} and either reset the local branch or merge the remote changes"
                    end
                    run_git(package, 'merge', fetch_commit)
                end
            end
        end

        def each_alternate_path(package)
            return enum_for(__method__, package) if !block_given?

            alternates.each do |path|
                path = path % [package.name]
                if File.directory?(path)
                    yield(path)
                end
            end
            nil
        end

        def checkout(package)
            base_dir = File.expand_path('..', package.importdir)
            if !File.directory?(base_dir)
                FileUtils.mkdir_p base_dir
            end

            clone_options = Array.new
            if with_submodules?
                clone_options << '--recurse-submodules'
            end
            each_alternate_path(package) do |path|
                clone_options << '--reference' << path
            end
            package.run(:import,
                Autobuild.tool('git'), 'clone', '-o', remote_name, *clone_options, repository, package.importdir, retry: true)

            update_remotes_configuration(package)
            if on_target_branch?(package)
                run_git(package, 'reset', '--hard', "#{remote_name}/#{branch}")
            else update(package, true)
            end
        end

        # Changes the repository this importer is pointing to
        def relocate(repository, options = Hash.new)
            @repository = repository.to_str
            @repository_id = options[:repository_id] ||
                "git:#{@repository}"
            @source_id = options[:source_id] ||
                "#{@repository_id} branch=#{self.branch} tag=#{self.tag} commit=#{self.commit}"
        end

        # Tests whether the given directory is a git repository
        def self.can_handle?(path)
            _, style = Git.resolve_git_dir(path)
            style == :normal
        end

        # Returns a hash that represents the configuration of a git importer
        # based on the information contained in the git configuration
        #
        # @raise [ArgumentError] if the path does not point to a git repository
        def self.vcs_definition_for(path, remote_name = 'autobuild')
            if !can_handle?(path)
                raise ArgumentError, "#{path} is either not a git repository, or a bare git repository"
            end

            Dir.chdir(path) do
                vars = `git config -l`.
                    split("\n").
                    inject(Hash.new) do |h, line|
                        k, v = line.strip.split('=', 2)
                        h[k] = v
                        h
                    end
                url = vars["remote.#{remote_name}.url"] ||
                    vars['remote.origin.url']
                if url
                    return Hash[:type => :git, :url => url]
                else
                    return Hash[:type => :git]
                end
            end
        end
    end

    # Creates a git importer which gets the source for the given repository and branch
    # URL +source+.
    def self.git(repository, branch = nil, options = {})
        Git.new(repository, branch, options)
    end
end

