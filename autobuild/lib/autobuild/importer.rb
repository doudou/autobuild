require 'autobuild/exceptions'

class Importer
    def initialize(options)
        @options = options
    end

    def import(package)
        srcdir = package.srcdir
        if File.directory?(srcdir)
            if $UPDATE
                update(package)
                patch(package)
            else
                puts "Not updating #{package.target}"
                return
            end

        elsif File.exists?(srcdir)
            raise ConfigException, "#{srcdir} exists but is not a directory"
        else
            begin
                checkout(package)
                patch(package)
            rescue ImportException
                FileUtils.rm_rf package.srcdir
                raise
            end
        end
    end

    private
    
    # We assume that package.srcdir already exists (checkout 
    # is supposed to have been called)
    def patchlist(package)
        "#{package.srcdir}/autobuild-patches"
    end

    def call_patch(package, reverse, file)
        patch = ($PROGRAMS['patch'] || 'patch')
        Dir.chdir(package.srcdir) {
            subcommand(package.target, 'patch', patch, '-p0', (reverse ? '-R' : nil), "<#{file}")
        }
    end

    def apply(package, path);   call_patch(package, false, path) end
    def unapply(package, path); call_patch(package, true, path)   end

    def patch(package)
        # Get the list of already applied patches
        patches_file = patchlist(package)
        cur_patches =   if !File.exists?(patches_file) then []
                        else
                            File.open(patches_file) do |f| 
                                f.readlines.collect { |path| path.rstrip } 
                            end
                        end

        # Do not be smart, remove all already applied patches
        # and then apply the new ones
        begin
            while p = cur_patches.pop
                unapply(package, p) 
            end

            @options[:patch].to_a.each { |p| 
                apply(package, p) 
                cur_patches << p
            }
        rescue SubcommandFailed => e
            raise ImportException.new(e), "can't patch #{package.target} (#{e.message})"
        ensure
            File.open(patchlist(package), 'w+') do |f|
                f.write(cur_patches.join("\n"))
            end
        end
    end
end
