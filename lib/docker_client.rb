require 'concurrent'
require 'pathname'

class DockerClient
  CONTAINER_WORKSPACE_PATH = '/workspace'
  DEFAULT_MEMORY_LIMIT = 256
  # Ralf: I suggest to replace this with the environment variable. Ask Hauke why this is not the case!
  LOCAL_WORKSPACE_ROOT = Rails.root.join('tmp', 'files', Rails.env)
  MINIMUM_MEMORY_LIMIT = 4
  RECYCLE_CONTAINERS = true
  RETRY_COUNT = 2

  attr_reader :container

  def self.check_availability!
    Timeout.timeout(config[:connection_timeout]) { Docker.version }
  rescue Excon::Errors::SocketError, Timeout::Error
    raise(Error, "The Docker host at #{Docker.url} is not reachable!")
  end

  def self.clean_container_workspace(container)
    local_workspace_path = local_workspace_path(container)
    if local_workspace_path &&  Pathname.new(local_workspace_path).exist?
      Pathname.new(local_workspace_path).children.each{ |p| p.rmtree}
      #FileUtils.rmdir(Pathname.new(local_workspace_path))
    end
  end

  def command_substitutions(filename)
    {class_name: File.basename(filename, File.extname(filename)).camelize, filename: filename, module_name: File.basename(filename, File.extname(filename)).underscore}
  end
  private :command_substitutions

  def self.config
    @config ||= CodeOcean::Config.new(:docker).read(erb: true)
  end

  def self.container_creation_options(execution_environment)
    {
      'Image' => find_image_by_tag(execution_environment.docker_image).info['RepoTags'].first,
      'Memory' => execution_environment.memory_limit.megabytes,
      'NetworkDisabled' => !execution_environment.network_enabled?,
      'OpenStdin' => true,
      'StdinOnce' => true
    }
  end

  def self.container_start_options(execution_environment, local_workspace_path)
    {
      'Binds' => mapped_directories(local_workspace_path),
      'PortBindings' => mapped_ports(execution_environment)
    }
  end

  def copy_file_to_workspace(options = {})
    FileUtils.cp(options[:file].native_file.path, local_file_path(options))
  end

  def self.create_container(execution_environment)
    tries ||= 0
    container = Docker::Container.create(container_creation_options(execution_environment))
    local_workspace_path = generate_local_workspace_path
    # container.start always creates the passed local_workspace_path on disk. Seems like we have to live with that, therefore we can also just create the empty folder ourselves.
    FileUtils.mkdir(local_workspace_path)
    container.start(container_start_options(execution_environment, local_workspace_path))
    container.start_time = Time.now
    container
  rescue Docker::Error::NotFoundError => error
    destroy_container(container)
    #(tries += 1) <= RETRY_COUNT ? retry : raise(error)
  end

  def create_workspace_files(container, submission)
    #clear directory (it should be empty anyhow)
    #Pathname.new(self.class.local_workspace_path(container)).children.each{ |p| p.rmtree}
    submission.collect_files.each do |file|
      FileUtils.mkdir_p(File.join(self.class.local_workspace_path(container), file.path || ''))
      if file.file_type.binary?
        copy_file_to_workspace(container: container, file: file)
      else
        create_workspace_file(container: container, file: file)
      end
    end
  end
  private :create_workspace_files

  def create_workspace_file(options = {})
    file = File.new(local_file_path(options), 'w')
    file.write(options[:file].content)
    file.close
  end
  private :create_workspace_file

  def self.destroy_container(container)
    Rails.logger.info('destroying container ' + container.to_s)
    container.stop.kill
    container.port_bindings.values.each { |port| PortPool.release(port) }
    clean_container_workspace(container)
    container.delete(force: true, v: true)
  end

  def execute_arbitrary_command(command, &block)
    execute_command(command, nil, block)
  end

  def execute_command(command, before_execution_block, output_consuming_block)
    #tries ||= 0
    @container = DockerContainerPool.get_container(@execution_environment)
    if @container
      before_execution_block.try(:call)
      send_command(command, @container, &output_consuming_block)
    else
      {status: :container_depleted}
    end
  rescue Excon::Errors::SocketError => error
    # socket errors seems to be normal when using exec
    # so lets ignore them for now
    #(tries += 1) <= RETRY_COUNT ? retry : raise(error)
  end

  [:run, :test].each do |cause|
    define_method("execute_#{cause}_command") do |submission, filename, &block|
      command = submission.execution_environment.send(:"#{cause}_command") % command_substitutions(filename)
      create_workspace_files = proc { create_workspace_files(container, submission) }
      execute_command(command, create_workspace_files, block)
    end
  end

  def self.find_image_by_tag(tag)
    Docker::Image.all.detect { |image| image.info['RepoTags'].flatten.include?(tag) }
  end

  def self.generate_local_workspace_path
    File.join(LOCAL_WORKSPACE_ROOT, SecureRandom.uuid)
  end

  def self.image_tags
    Docker::Image.all.map { |image| image.info['RepoTags'] }.flatten.reject { |tag| tag.include?('<none>') }
  end

  def initialize(options = {})
    @execution_environment = options[:execution_environment]
    @image = self.class.find_image_by_tag(@execution_environment.docker_image)
    fail(Error, "Cannot find image #{@execution_environment.docker_image}!") unless @image
  end

  def self.initialize_environment
    unless config[:connection_timeout] && config[:workspace_root]
      fail(Error, 'Docker configuration missing!')
    end
    Docker.url = config[:host] if config[:host]
    check_availability!
    FileUtils.mkdir_p(LOCAL_WORKSPACE_ROOT)
  end

  def local_file_path(options = {})
    File.join(self.class.local_workspace_path(options[:container]), options[:file].path || '', options[:file].name_with_extension)
  end
  private :local_file_path

  def self.local_workspace_path(container)
    Pathname.new(container.binds.first.split(':').first.sub(config[:workspace_root], LOCAL_WORKSPACE_ROOT.to_s)) if container.binds.present?
  end

  def self.mapped_directories(local_workspace_path)
    remote_workspace_path = local_workspace_path.sub(LOCAL_WORKSPACE_ROOT.to_s, config[:workspace_root])
    # create the string to be returned
    ["#{remote_workspace_path}:#{CONTAINER_WORKSPACE_PATH}"]
  end

  def self.mapped_ports(execution_environment)
    (execution_environment.exposed_ports || '').gsub(/\s/, '').split(',').map do |port|
      ["#{port}/tcp", [{'HostPort' => PortPool.available_port.to_s}]]
    end.to_h
  end

  def self.pull(docker_image)
    `docker pull #{docker_image}` if docker_image
  end

  def self.return_container(container, execution_environment)
    clean_container_workspace(container)
    DockerContainerPool.return_container(container, execution_environment)
  end
  #private :return_container

  def send_command(command, container, &block)
    result = {status: :failed, stdout: '', stderr: ''}
    Timeout.timeout(@execution_environment.permitted_execution_time.to_i) do
      output = container.exec(['bash', '-c', command])
      Rails.logger.info "output from container.exec"
      Rails.logger.info output
      result = {status: output[2] == 0 ? :ok : :failed, stdout: output[0].join, stderr: output[1].join}
    end
    # if we use pooling and recylce the containers, put it back. otherwise, destroy it.
    (DockerContainerPool.config[:active] && RECYCLE_CONTAINERS) ? self.class.return_container(container, @execution_environment) : self.class.destroy_container(container)
    result
  rescue Timeout::Error
    Rails.logger.info('got timeout error for container ' + container.to_s)

    # remove container from pool, then destroy it
    (DockerContainerPool.config[:active]) ? DockerContainerPool.remove_from_all_containers(container, @execution_environment) :

    # destroy container
    self.class.destroy_container(container)

    # if we recylce containers, we start a fresh one
    if(DockerContainerPool.config[:active] && RECYCLE_CONTAINERS)
      # create new container and add it to @all_containers and @containers.
      container = self.class.create_container(@execution_environment)
      DockerContainerPool.add_to_all_containers(container, @execution_environment)
    end
    {status: :timeout}
  end
  private :send_command

  class Error < RuntimeError; end
end
