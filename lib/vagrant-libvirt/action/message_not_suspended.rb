module VagrantPlugins
  module Libvirt
    module Action
      class MessageNotSuspended
        def initialize(app, env)
          @app = app
        end

        def call(env)
          env[:ui].info(I18n.t("vagrant_libvirt.not_suspended"))
          @app.call(env)
        end
      end
    end
  end
end
