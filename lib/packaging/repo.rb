module Pkg::Repo

  class << self
    def create_signed_repo_archive(path_to_repo, name_of_archive, versioning)
      tar = Pkg::Util::Tool.check_tool('tar')
      Dir.chdir("pkg") do
        if versioning == 'ref'
          local_target = File.join(Pkg::Config.project, Pkg::Config.ref)
        elsif versioning == 'version'
          local_target = File.join(Pkg::Config.project, Pkg::Util::Version.dot_version)
        end
        Dir.chdir(local_target) do
          if Pkg::Util::File.empty_dir?(path_to_repo)
            if ENV['FAIL_ON_MISSING_TARGET'] == "true"
              raise "ERROR: missing packages under #{path_to_repo}"
            else
              warn "Skipping #{name_of_archive} because #{path_to_repo} has no files"
            end
          else
            puts "Archiving #{path_to_repo} as #{name_of_archive}"
            stdout, _, _ = Pkg::Util::Execution.capture3("#{tar} --owner=0 --group=0 --create --gzip --file #{File.join('repos', "#{name_of_archive}.tar.gz")} #{path_to_repo}")
            stdout
          end
        end
      end
    end

    def create_all_repo_archives(project, versioning)
      platforms = Pkg::Config.platform_repos
      platforms.each do |platform|
        archive_name = "#{project}-#{platform['name']}"
        create_signed_repo_archive(platform['repo_location'], archive_name, versioning)
      end
    end

    def directories_that_contain_packages(artifact_directory, pkg_ext)
      cmd = "[ -d #{artifact_directory} ] || exit 1 && "
      cmd << "pushd #{artifact_directory} > /dev/null && "
      cmd << "find . -name '*.#{pkg_ext}' -print0 | xargs --no-run-if-empty -0 -I {} dirname {} "
      stdout, stderr = Pkg::Util::Net.remote_ssh_cmd(Pkg::Config.distribution_server, cmd, true)
      return stdout.split
    rescue => e
      fail "Could not retrieve directories that contain #{pkg_ext} packages in #{Pkg::Config.distribution_server}:#{artifact_directory}"
    end

    def populate_repo_directory(artifact_parent_directory)
      cmd = "[ -d #{artifact_parent_directory}/artifacts ] || exit 1 && "
      cmd << "pushd #{artifact_parent_directory} > /dev/null && "
      cmd << 'rsync --archive --verbose --one-file-system --ignore-existing artifacts/ repos/ '
      Pkg::Util::Net.remote_ssh_cmd(Pkg::Config.distribution_server, cmd)
    rescue => e
      fail "Could not populate repos directory in #{Pkg::Config.distribution_server}:#{artifact_parent_directory}"
    end
  end
end
