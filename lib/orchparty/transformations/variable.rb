module Orchparty
  module Transformations
    class Variable

      def initialize(opts = {})
        @force_variable_definition = opts[:force_variable_definition]
      end

      def transform(ast)
        ast.applications.each do |_, application|
          ctx = build_context(application: application)
          application.services = application.services.each do |_, service|
            resolve(ctx, service)
          end
          application.volumes = application.volumes.each do |_, volume|
            resolve(ctx, volume) if volume
          end
        end
        ast
      end

      def resolve(ctx, subject)
        subject.deep_transform_values! do |v|
          if v.respond_to?(:call)
            ctx = merge_service(ctx, subject)
            eval_value(ctx, v)
          elsif v.is_a? Array
            v.map do |v|
              if v.respond_to?(:call)
                ctx = merge_service(ctx, subject)
                eval_value(ctx, v)
              else
                v
              end
            end
          else
            v
          end
        end
      end

      def eval_value(context, value)
        context.instance_exec(&value)
      end

      def merge_service(ctx, service)
        return ctx if service._variables.nil?

        ctx.merge!(service._variables)
        ctx.merge!({ service: service.merge(service._variables) })
      end

      def build_context(application:)
        variables = application._variables || {}
        variables = variables.merge({ application: application.merge(application._variables) })

        context = Context.new(variables)
        context._force_variable_definition = @force_variable_definition
        context
      end
    end
  end
end
