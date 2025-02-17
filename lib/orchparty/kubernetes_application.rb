require 'erb'
require 'erubis'
require 'open3'
require 'ostruct'
require 'yaml'
require 'tempfile'
require 'active_support'
require 'active_support/core_ext'

module Orchparty
  module Services
    class Context
      attr_accessor :cluster_name
      attr_accessor :namespace
      attr_accessor :dir_path
      attr_accessor :app_config

      def initialize(cluster_name: , namespace:, file_path: , app_config:)
        self.cluster_name = cluster_name
        self.namespace = namespace
        self.dir_path = file_path
        self.app_config = app_config
      end

      def template(file_path, helm, flag: "-f ", fix_file_path: nil)
        return "" unless file_path
        file_path = File.join(self.dir_path, file_path)
        if(file_path.end_with?(".erb"))
          helm.application = OpenStruct.new(cluster_name: cluster_name, namespace: namespace)
          template = Erubis::Eruby.new(File.read(file_path))
          template.filename = file_path
          yaml = template.result(helm.get_binding)
          file = Tempfile.new("kube-deploy.yaml")
          file.write(yaml)
          file.close
          file_path = file.path
        end
        "#{flag}#{fix_file_path || file_path}"
      end

      def print_install(helm)
        puts "---"
        puts install_cmd(helm, value_path(helm))
        puts upgrade_cmd(helm, value_path(helm))
        puts "---"
        puts File.read(template(value_path(helm), helm, flag: "")) if value_path(helm)
      end

      # On 05.02.2021 we have decided that it would be best to print both commands.
      # This way it would be possible to debug both upgrade and install and also people would not see git diffs all the time.
      def print_upgrade(helm)
        print_install(helm)
      end

      def upgrade(helm)
        run_command(upgrade_cmd(helm))
      end

      def install(helm)
        run_command(install_cmd(helm))
      end

      private

      def run_command(command)
        puts "Executing command: #{command}"
        stdout_and_stderr_str, status = Open3.capture2e(command)
        unless status.success?
          # Codes <7, 31, 49> mean print <inverted, red, on default>.
          puts format("\033[%d;%d;%dm%s\033[0m", 7, 31, 49, 'The command failed!')
        end
        puts stdout_and_stderr_str
        puts

        status.success?
      end

      def create_namespace_cmd
        "kubectl --context #{cluster_name} create namespace #{namespace} --dry-run=client -o yaml | kubectl --context #{cluster_name} apply -f -"
      end
    end

    class Helm < Context
      def value_path(helm)
        helm[:values]
      end

      def upgrade_cmd(helm, fix_file_path = nil)
        "helm upgrade --namespace #{namespace} --kube-context #{cluster_name} --version #{helm.version} #{helm.name} #{helm.chart} #{template(value_path(helm), helm, fix_file_path: fix_file_path)}"
      end

      def install_cmd(helm, fix_file_path = nil)
        "helm install --create-namespace --namespace #{namespace} --kube-context #{cluster_name} --version #{helm.version} #{helm.name} #{helm.chart} #{template(value_path(helm), helm, fix_file_path: fix_file_path)}"
      end
    end

    class Apply < Context
      def value_path(apply)
        apply[:name]
      end

      def upgrade_cmd(apply, fix_file_path = nil)
        "kubectl apply --namespace #{namespace} --context #{cluster_name} #{template(value_path(apply), apply, fix_file_path: fix_file_path)}"
      end

      def install_cmd(apply, fix_file_path = nil)
        create_namespace_cmd + "&& kubectl apply --namespace #{namespace} --context #{cluster_name} #{template(value_path(apply), apply, fix_file_path: fix_file_path)}"
      end
    end

    class CreateReplace < Context
      def value_path(config)
        config[:name]
      end

      def upgrade_cmd(config, fix_file_path = nil)
        "kubectl replace --namespace #{namespace} --context #{cluster_name} #{template(value_path(config), config, fix_file_path: fix_file_path)}"
      end

      def install_cmd(config, fix_file_path = nil)
        create_namespace_cmd + "&& kubectl create --namespace #{namespace} --context #{cluster_name} #{template(value_path(config), config, fix_file_path: fix_file_path)}"
      end
    end

    class SecretGeneric < Context
      def value_path(secret)
        secret[:from_file]
      end

      def upgrade_cmd(secret, fix_file_path=nil)
        "kubectl --namespace #{namespace} --context #{cluster_name} create secret generic --dry-run -o yaml #{secret[:name]}  #{template(value_path(secret), secret, flag: "--from-file=", fix_file_path: fix_file_path)} | kubectl --context #{cluster_name} apply -f -"
      end

      def install_cmd(secret, fix_file_path=nil)
        create_namespace_cmd + "&& kubectl --namespace #{namespace} --context #{cluster_name} create secret generic --dry-run -o yaml #{secret[:name]}  #{template(value_path(secret), secret, flag: "--from-file=", fix_file_path: fix_file_path)} | kubectl --context #{cluster_name} apply -f -"
      end
    end

    class Label < Context
      def print_install(label)
        puts "---"
        puts install_cmd(label)
      end

      def print_upgrade(label)
        puts "---"
        puts upgrade_cmd(label)
      end

      def upgrade_cmd(label)
        "kubectl --namespace #{namespace} --context #{cluster_name} label --overwrite #{label[:resource]} #{label[:name]} #{label["value"]}"
      end

      def install_cmd(label)
        create_namespace_cmd + "&& kubectl --namespace #{namespace} --context #{cluster_name} label --overwrite #{label[:resource]} #{label[:name]} #{label["value"]}"
      end
    end

    class Wait < Context
      def print_install(wait)
        puts "---"
        puts wait.cmd
      end

      def print_upgrade(wait)
        puts "---"
        puts wait.cmd
      end

      def upgrade(wait)
        eval(wait.cmd)
        true
      end

      def install(wait)
        eval(wait.cmd)
        true
      end
    end

    class Chart < Context
      class CleanBinding
        def get_binding(params)
          params.instance_eval do
            binding
          end
        end
      end

      def build_chart(chart)
        params = chart._services.map {|s| app_config.services[s.to_sym] }.map{|s| [s.name, s]}.to_h
        Dir.mktmpdir do |dir|
          run(templates_path: File.expand_path(chart.template, self.dir_path), params: params, output_chart_path: dir, chart: chart)
          yield dir
        end
      end

      def run(templates_path:, params:, output_chart_path:, chart: )
        system("mkdir -p #{output_chart_path}")
        system("mkdir -p #{File.join(output_chart_path, 'templates')}")

        system("cp #{File.join(templates_path, 'values.yaml')} #{File.join(output_chart_path, 'values.yaml')}")
        system("cp #{File.join(templates_path, '.helmignore')} #{File.join(output_chart_path, '.helmignore')}")
        system("cp #{File.join(templates_path, 'templates/_helpers.tpl')} #{File.join(output_chart_path, 'templates/_helpers.tpl')}")

        generate_chart_yaml(
          templates_path: templates_path,
          output_chart_path: output_chart_path,
          chart_name: chart.name,
        )

        params.each do |app_name, subparams|
          subparams[:chart] = chart
          generate_documents_from_erbs(
            templates_path: templates_path,
            app_name: app_name,
            params: subparams,
            output_chart_path: output_chart_path
          )
        end
      end

      def generate_documents_from_erbs(templates_path:, app_name:, params:, output_chart_path:)
        if params[:kind].nil?
          warn "ERROR: Could not generate service '#{app_name}'. Missing key: 'kind'."
          exit 1
        end

        kind = params.fetch(:kind)

        Dir[File.join(templates_path, kind, '*.erb')].each do |template_path|
          template_name = File.basename(template_path, '.erb')
          output_path = File.join(output_chart_path, 'templates', "#{app_name}-#{template_name}")

          template = Erubis::Eruby.new(File.read(template_path))
          template.filename = template_path
          params.app_name = app_name
          params.templates_path = templates_path
          document = template.result(CleanBinding.new.get_binding(params))
          File.write(output_path, document)
        end
      end

      def generate_chart_yaml(templates_path:, output_chart_path:, chart_name: )
        template_path = File.join(templates_path, 'Chart.yaml.erb')
        output_path = File.join(output_chart_path, 'Chart.yaml')

        template = Erubis::Eruby.new(File.read(template_path))
        template.filename = template_path
        params = Hashie::Mash.new(chart_name: chart_name)
        document = template.result(CleanBinding.new.get_binding(params))
        File.write(output_path, document)
      end

      def print_install(chart)
        build_chart(chart) do |chart_path|
          command = "helm template --namespace #{namespace} --kube-context #{cluster_name} #{chart.name} #{chart_path}"
          stdout_str, stderr_str, status = Open3.capture3(command)

          if status.success?
            puts "---"
            puts install_cmd(chart, 'tmp.yaml')
            puts upgrade_cmd(chart, 'tmp.yaml')
            puts stdout_str
          else
            puts "ERROR when building chart: #{chart.name}"
            puts "Command was: #{command}"
            puts stdout_str
            puts stderr_str

            if stderr_str =~ /YAML parse error on ([^:]+):/
              file_path = $1
              # For some reason the path contains the chart name in the first position, we have to remove that
              file_path.gsub!("#{chart.name}/", '')
              # This is the absolute path:
              file_path = File.join(chart_path, file_path)
              puts "\nContent of #{file_path}:"
              count = 0
              File.readlines(file_path).each do |line|
                puts format('%3d: %s', count, line) # We prefix the line to make it more visible in the diff that is done on it at a later stage
                count += 1
              end
            end
          end
        end
      end

      def print_upgrade(chart)
        print_install(chart)
      end

      def install(chart)
        build_chart(chart) do |chart_path|
          run_command(install_cmd(chart, chart_path))
        end
      end

      def upgrade(chart)
        build_chart(chart) do |chart_path|
          run_command(upgrade_cmd(chart, chart_path))
        end
      end

      def install_cmd(chart, chart_path)
        "helm install --create-namespace --namespace #{namespace} --kube-context #{cluster_name} #{chart.name} #{chart_path}"
      end

      def upgrade_cmd(chart, chart_path)
        "helm upgrade --namespace #{namespace} --kube-context #{cluster_name} #{chart.name} #{chart_path}"
      end
    end
  end
end

class KubernetesApplication
  attr_accessor :cluster_name
  attr_accessor :file_path
  attr_accessor :namespace
  attr_accessor :app_config

  def initialize(app_config: [], namespace:, cluster_name:, file_name:)
    self.file_path = Pathname.new(file_name).parent.expand_path
    self.cluster_name = cluster_name
    self.namespace = namespace
    self.app_config = app_config
  end

  def install
    results = []
    each_service do |service, config|
      results << service.install(config)
    end

    if results.all?
      puts 'Done ✅'
    else
      puts 'Some commands failed ❗️❗️❗️'
    end
  end

  def upgrade
    results = []
    each_service do |service, config|
      results << service.upgrade(config)
    end

    if results.all?
      puts 'Done ✅'
    else
      puts 'Some commands failed ❗️❗️❗️'
    end
  end

  def print_install
    each_service do |service, config|
      service.print_install(config)
    end
  end

  def combine_charts(app_config)
    services = app_config._service_order.map(&:to_s)
    app_config._service_order.each do |name|
      current_service = app_config[:services][name]
      if current_service._type == "chart"
        current_service._services.each do |n|
          services.delete n.to_s
        end
      end
    end
    services
  end

  def each_service
    services = combine_charts(app_config)
    services.each do |name|
      config = app_config[:services][name]
      service = "::Orchparty::Services::#{config._type.classify}".constantize.new(cluster_name: cluster_name, namespace: namespace, file_path: file_path, app_config: app_config)
      yield(service, config)
    end
  end
end
