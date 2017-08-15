def sign_rpm(rpm, sign_flags = nil)

  # To enable support for wrappers around rpm and thus support for gpg-agent
  # rpm signing, we have to be able to tell the packaging repo what binary to
  # use as the rpm signing tool.
  #
  rpm_cmd = ENV['RPM'] || Pkg::Util::Tool.find_tool('rpm')

  # If we're using the gpg agent for rpm signing, we don't want to specify the
  # input for the passphrase, which is what '--passphrase-fd 3' does. However,
  # if we're not using the gpg agent, this is required, and is part of the
  # defaults on modern rpm. The fun part of gpg-agent signing of rpms is
  # specifying that the gpg check command always return true
  #
  if Pkg::Util.boolean_value(ENV['RPM_GPG_AGENT'])
    gpg_check_cmd = "--define '%__gpg_check_password_cmd /bin/true'"
  else
    input_flag = "--passphrase-fd 3"
  end

  # Try this up to 5 times, to allow for incorrect passwords
  Pkg::Util::Execution.retry_on_fail(:times => 5) do
    # This definition of %__gpg_sign_cmd is the default on modern rpm. We
    # accept extra flags to override certain signing behavior for older
    # versions of rpm, e.g. specifying V3 signatures instead of V4.
    #
    sh "#{rpm_cmd} #{gpg_check_cmd} --define '%_gpg_name #{Pkg::Util::Gpg.key}' --define '%__gpg_sign_cmd %{__gpg} gpg #{sign_flags} #{input_flag} --batch --no-verbose --no-armor --no-secmem-warning -u %{_gpg_name} -sbo %{__signature_filename} %{__plaintext_filename}' --addsign #{rpm}"
  end

end

def sign_legacy_rpm(rpm)
  sign_rpm(rpm, "--force-v3-sigs --digest-algo=sha1")
end

def rpm_has_sig(rpm)
  %x(rpm -Kv #{rpm} | grep "#{Pkg::Util::Gpg.key.downcase}" &> /dev/null)
  $?.success?
end

def sign_deb_changes(file)
  # Lazy lazy lazy lazy lazy
  sign_program = "-p'gpg --use-agent --no-tty'" if ENV['RPM_GPG_AGENT']
  sh "debsign #{sign_program} --re-sign -k#{Pkg::Config.gpg_key} #{file}"
end

namespace :pl do
  desc "Sign the tarball, defaults to PL key, pass GPG_KEY to override or edit build_defaults"
  task :sign_tar do
    unless Pkg::Config.vanagon_project
      File.exist?("pkg/#{Pkg::Config.project}-#{Pkg::Config.version}.tar.gz") or fail "No tarball exists. Try rake package:tar?"
      Pkg::Util::Gpg.load_keychain if Pkg::Util::Tool.find_tool('keychain')
      Pkg::Util::Gpg.sign_file "pkg/#{Pkg::Config.project}-#{Pkg::Config.version}.tar.gz"
    end
  end

  desc "Sign the Arista EOS swix packages, defaults to PL key, pass GPG_KEY to override or edit build_defaults"
  task :sign_swix do
    packages = Dir["pkg/**/*.swix"]
    unless packages.empty?
      Pkg::Util::Gpg.load_keychain if Pkg::Util::Tool.find_tool('keychain')
      packages.each do |swix_package|
        Pkg::Util::Gpg.sign_file swix_package
      end
    end
  end

  desc "Detach sign any solaris svr4 packages"
  task :sign_svr4 do
    unless Dir["pkg/**/*.pkg.gz"].empty?
      Pkg::Util::Gpg.load_keychain if Pkg::Util::Tool.find_tool('keychain')
      Dir["pkg/**/*.pkg.gz"].each do |pkg|
        Pkg::Util::Gpg.sign_file pkg
      end
    end
  end

  desc "Sign mocked rpms, Defaults to PL Key, pass GPG_KEY to override"
  task :sign_rpms, :root_dir do |t, args|
    rpm_dir = args.root_dir || "pkg"

    all_rpms = Dir["#{rpm_dir}/**/*.rpm"]

    v3_rpms = []
    v4_rpms = []
    all_rpms.each do |rpm|
      platform_tag = Pkg::Paths.tag_from_artifact_path(rpm)

      # We don't sign AIX rpms
      next if platform_tag.include?('aix')

      sig_type = Pkg::Platforms.signature_format_for_tag(platform_tag)
      case sig_type
      when 'v3'
        v3_rpms << rpm
      when 'v4'
        v4_rpms << rpm
      else
        fail "Cannot find signature type for package '#{rpm}'"
      end
    end

    unless v3_rpms.empty?
      puts "Signing old rpms..."
      sign_legacy_rpm(v3_rpms.join(' '))
    end

    unless v4_rpms.empty?
      puts "Signing modern rpms..."
      sign_rpm(v4_rpms.join(' '))
    end

    # Now we hardlink them back in
    Dir["#{rpm_dir}/**/*.noarch.rpm"].each do |rpm|
      platform_tag = Pkg::Paths.tag_from_artifact_path(rpm)
      platform, version, architecture = Pkg::Platforms.parse_platform_tag(platform_tag)
      supported_arches = Pkg::Platforms.arches_for_platform_version(platform, version)
      cd File.dirname(rpm) do
        noarch_rpm = File.basename(rpm)
        supported_arches.each do |arch|
          arch_dir = File.join('..', arch)
          FileUtils.mkdir_p(arch_dir)
          unless File.exist?(File.join(arch_dir, noarch_rpm))
            FileUtils.ln(noarch_rpm, arch_dir, :force => true, :verbose => true)
          end
        end
      end
    end
  end

  desc "Sign ips package, uses PL certificates by default, update privatekey_pem, certificate_pem, and ips_inter_cert in build_defaults.yaml to override."
  task :sign_ips do
    Pkg::IPS.sign unless Dir['pkg/**/*.p5p'].empty?
  end

  if Pkg::Config.build_gem
    desc "Sign built gems, defaults to PL key, pass GPG_KEY to override or edit build_defaults"
    task :sign_gem do
      FileList["pkg/#{Pkg::Config.gem_name}-#{Pkg::Config.gemversion}*.gem"].each do |gem|
        puts "signing gem #{gem}"
        Pkg::Util::Gpg.sign_file(gem)
      end
    end
  end

  desc "Check if all rpms are signed"
  task :check_rpm_sigs do
    signed = TRUE
    rpms = Dir["pkg/**/*.rpm"]
    print 'Checking rpm signatures'
    rpms.each do |rpm|
      if rpm_has_sig rpm
        print '.'
      else
        puts "#{rpm} is unsigned."
        signed = FALSE
      end
    end
    fail unless signed
    puts "All rpms signed"
  end

  desc "Sign generated debian changes files. Defaults to PL Key, pass GPG_KEY to override"
  task :sign_deb_changes do
    begin
      change_files = Dir["pkg/**/*.changes"]
      unless change_files.empty?
        Pkg::Util::Gpg.load_keychain if Pkg::Util::Tool.find_tool('keychain')
        sign_deb_changes("pkg/**/*.changes")
      end
    ensure
      Pkg::Util::Gpg.kill_keychain
    end
  end

  desc "Sign OSX packages"
  task :sign_osx => "pl:fetch" do
    Pkg::OSX.sign unless Dir['pkg/**/*.dmg'].empty?
  end

  desc "Sign MSI packages"
  task :sign_msi => "pl:fetch" do
    Pkg::MSI.sign unless Dir['pkg/**/*.msi'].empty?
  end

  ##
  # This crazy piece of work establishes a remote repo on the distribution
  # server, ships our packages out to it, signs them, and brings them back.
  #
  namespace :jenkins do
    desc "Sign all locally staged packages on #{Pkg::Config.distribution_server}"
    task :sign_all => "pl:fetch" do
      Dir["pkg/*"].empty? and fail "There were files found in pkg/. Maybe you wanted to build/retrieve something first?"

      # Because rpms and debs are laid out differently in PE under pkg/ they
      # have a different sign task to address this. Rather than create a whole
      # extra :jenkins task for signing PE, we determine which sign task to use
      # based on if we're building PE.
      # We also listen in on the environment variable SIGNING_BUNDLE. This is
      # _NOT_ intended for public use, but rather with the internal promotion
      # workflow for Puppet Enterprise. SIGNING_BUNDLE is the path to a tarball
      # containing a git bundle to be used as the environment for the packaging
      # repo in a signing operation.
      signing_bundle = ENV['SIGNING_BUNDLE']
      rpm_sign_task = Pkg::Config.build_pe ? "pe:sign_rpms" : "pl:sign_rpms"
      deb_sign_task = Pkg::Config.build_pe ? "pe:sign_deb_changes" : "pl:sign_deb_changes"
      sign_tasks    = [rpm_sign_task, deb_sign_task]
      sign_tasks    << "pl:sign_tar" if Pkg::Config.build_tar
      sign_tasks    << "pl:sign_gem" if Pkg::Config.build_gem
      sign_tasks    << "pl:sign_osx" if Pkg::Config.build_dmg || Pkg::Config.vanagon_project
      sign_tasks    << "pl:sign_swix" if Pkg::Config.vanagon_project
      sign_tasks    << "pl:sign_svr4" if Pkg::Config.vanagon_project
      sign_tasks    << "pl:sign_ips" if Pkg::Config.vanagon_project
      sign_tasks    << "pl:sign_msi" if Pkg::Config.build_msi || Pkg::Config.vanagon_project
      remote_repo   = Pkg::Util::Net.remote_bootstrap(Pkg::Config.distribution_server, 'HEAD', nil, signing_bundle)
      build_params  = Pkg::Util::Net.remote_buildparams(Pkg::Config.distribution_server, Pkg::Config)
      Pkg::Util::Net.rsync_to('pkg', Pkg::Config.distribution_server, remote_repo)
      Pkg::Util::Net.remote_ssh_cmd(Pkg::Config.distribution_server, "cd #{remote_repo} ; rake #{sign_tasks.join(' ')} PARAMS_FILE=#{build_params}")
      Pkg::Util::Net.rsync_from("#{remote_repo}/pkg/", Pkg::Config.distribution_server, "pkg/")
      Pkg::Util::Net.remote_ssh_cmd(Pkg::Config.distribution_server, "rm -rf #{remote_repo}")
      Pkg::Util::Net.remote_ssh_cmd(Pkg::Config.distribution_server, "rm #{build_params}")
      puts "Signed packages staged in 'pkg/ directory"
    end
  end
end
