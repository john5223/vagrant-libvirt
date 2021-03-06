require 'log4r'
require 'vagrant/util/network_ip'
require 'vagrant/util/scoped_hash_override'

module VagrantPlugins
  module Libvirt
    module Action

      # Create network interfaces for domain, before domain is running.
      # Networks for connecting those interfaces should be already prepared.
      class CreateNetworkInterfaces
        include VagrantPlugins::Libvirt::Util::ErbTemplate
        include VagrantPlugins::Libvirt::Util::LibvirtUtil
        include Vagrant::Util::NetworkIP
        include Vagrant::Util::ScopedHashOverride

        def initialize(app, env)
          @logger = Log4r::Logger.new("vagrant_libvirt::action::create_network_interfaces")
          @app = app
        end

        def call(env)
          # Get domain first.
          begin
            domain = env[:libvirt_compute].client.lookup_domain_by_uuid(
              env[:machine].id.to_s)
          rescue => e
            raise Errors::NoDomainError,
              :error_message => e.message
          end

          # Setup list of interfaces before creating them.
          adapters = []

          # Assign main interface for provisioning to first slot.
          # Use network 'default' as network for ssh connecting and
          # machine provisioning.
          #
          # TODO Network name with DHCP for first interface should be
          # configurable.
          adapters[0] = {
            :network_name => 'default'
          }

          # Assign interfaces to slots.
          env[:machine].config.vm.networks.each do |type, options|
            # Only private network is supported now. Port forwarding and public
            # network are not supported via libvirt API, so they are not
            # implemented in this provider.
            next if type != :private_network

            # Get options for this interface. Options can be specified in
            # Vagrantfile in short format (:ip => ...), or provider format
            # (:libvirt__network_name => ...).
            options = scoped_hash_override(options, :libvirt)
            options = { :netmask => '255.255.255.0' }.merge(options)

            # TODO fill first ifaces with adapter option specified.
            if options[:adapter]
              if adapters[options[:adapter]]
                raise Errors::InterfaceSlotNotAvailable
              end

              free_slot = options[:adapter].to_i
            else
              free_slot = find_empty(adapters, start=1)
              raise Errors::InterfaceSlotNotAvailable if free_slot == nil
            end

            # We have slot for interface, fill it with interface configuration.
            adapters[free_slot] = options
            adapters[free_slot][:network_name] = interface_network(
              env[:libvirt_compute].client, adapters[free_slot])
          end

          # Create each interface as new domain device.
          adapters.each_with_index do |iface_configuration, slot_number|
            @iface_number = slot_number
            @network_name = iface_configuration[:network_name]

            message = "Creating network interface eth#{@iface_number}"
            message << " connected to network #{@network_name}."
            @logger.info(message)

            begin
              domain.attach_device(to_xml('interface'))
            rescue => e
              raise Errors::AttachDeviceError,
                :error_message => e.message
            end
          end

          # Continue the middleware chain. 
          @app.call(env)

          # Configure interfaces that user requested. Machine should be up and
          # running now.
          networks_to_configure = []

          adapters.each_with_index do |options, slot_number|
            # Skip configuring first interface. It's used for provisioning and
            # it has to be available during provisioning - ifdown command is
            # not acceptable here.
            next if slot_number == 0

            network = {
              :interface => slot_number,
              #:mac => ...,
            }

            if options[:ip]
              network = {
                :type    => :static,
                :ip      => options[:ip],
                :netmask => options[:netmask],
              }.merge(network)
            else
              network[:type] = :dhcp
            end

            networks_to_configure << network
          end

          env[:ui].info I18n.t("vagrant.actions.vm.network.configuring")
          env[:machine].guest.capability(
            :configure_networks, networks_to_configure) 
        end

        private

        def find_empty(array, start=0, stop=8)
          for i in start..stop
            return i if !array[i]
          end
          return nil
        end

        # Return network name according to interface options.
        def interface_network(libvirt_client, options)
          return options[:network_name] if options[:network_name]

          # Get list of all (active and inactive) libvirt networks.
          available_networks = libvirt_networks(libvirt_client)

          if options[:ip]
            address = network_address(options[:ip], options[:netmask])
            available_networks.each do |network|
              return network[:name] if address == network[:network_address]
            end
          end

          # TODO Network default can be missing or named different.
          return 'default'
        end
      end
    end
  end
end
