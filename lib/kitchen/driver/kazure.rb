# -*- encoding: utf-8 -*-
#
# Author:: Grant Ellis (<grant.ellis@marks-and-spencer.com>)
#
# Copyright (C) 2014, Grant Ellis
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'azure'
require 'securerandom'
require 'openssl'
require 'nokogiri'

module Kitchen

  module Driver

    # Azure driver for Kitchen.
    #
    # @author Grant Ellis <grant.ellis@marks-and-spencer.com>
    class Kazure < Kitchen::Driver::SSHBase
      
      default_config :port, 2222
      default_config :username, "azureuser"
      default_config :location, "West US"
      default_config :size, "Small"
      default_config :publish_settings_file do |driver|
	driver.publish_settings_file
      end
      default_config :subscription do |driver|
	driver.subscription
      end
      
      required_config :publish_settings_file
      required_config :subscription
      
      def self.cloud_service
	@@cloud_service ||= "test-kitchen-" + SecureRandom.hex(6)
      end
      
      def initialize(config)
	debug("Initialize called. Config: " + config.inspect)
	#debug("For shits and giggles: #{Kazure.cloud_service}")
	settings = Nokogiri::XML(File.open(config[:publish_settings_file]))
	subscriptions = settings.xpath("//Subscription")
	sub_data = subscriptions.find{ |s| s.attributes["Name"].value == config[:subscription]}
	cert = sub_data["ManagementCertificate"]
	sub_id = sub_data["Id"]
	
	
	FileUtils.mkdir_p(File.join(config[:kitchen_root], %w{.kitchen kitchen-azure}))
	File.open(File.join(config[:kitchen_root], %w{.kitchen kitchen-azure}, "management_cert.pfx"),"w") do |f|
	  f.write(cert)
	end
	
	Azure.configure do |c|
	  c.management_certificate = File.join(config[:kitchen_root], %w{.kitchen kitchen-azure}, "management_cert.pfx")
	  c.subscription_id = sub_id
	  c.management_endpoint = "https://management.core.windows.net"
	end
	
	super
      end

      def create(state)
	debug("Config: #{config.inspect}")
	debug("Instance: #{instance.inspect}")
	debug("Platform: #{instance.platform.name}")
	info("Searching for images for distro #{instance.platform.name}")
	distro = instance.platform.name.match(/(\w+)[\-_](\d+)[\-_\.](\d+)/)
	@cloud_service = "test-kitchen-" + SecureRandom.hex(6)
	
	return if state[:cloud_service]
	
	if (distro.nil? || (distro.length != 4))
	  raise "Unable to parse linux distro"
	end
	
	flavour = distro[1]
	maj = distro[2]
	min = distro[3]
	vmis = Azure::VirtualMachineImageManagementService.new
	image = vmis.list_virtual_machine_images.select{ |i| i.name =~ /#{flavour}.*#{maj}[\-_\.]#{min}/i }.last
	raise "Unable to find matching image for #{instance.platform.name}" if image.nil?
	
	generate_ssh_certs
	
	vm_params = { 
	  :vm_name => instance.name,
	  :vm_user => config[:username],
	  :image => image.name,
	  :location => config[:location]
	}
	vm_options = {
	  :storage_account_name => "testkitchenstore",
	  :ssh_port => config[:port],
	  :cloud_service_name => @cloud_service,
	  :vm_size => config[:size],
	  :private_key_file => File.join(cert_dir , "azure.key"),
	  :certificate_file => File.join(cert_dir , "azure.pem")
	}
	
	@instance_opts = vm_params.merge(vm_options)
	
	state[:hostname] = @cloud_service + ".cloudapp.net"
	state[:ssh_key] = vm_options[:private_key_file]
	state[:vm_name] = vm_params[:vm_name]
	state[:cloud_service] = vm_options[:cloud_service_name]
	
	debug("Instance Options: " + @instance_opts.inspect)
	
	vms = Azure::VirtualMachineManagementService.new
	vms.create_virtual_machine(vm_params, vm_options)
	
	## TODO: Logic to wait until VM is ReadyRole
	while ((vm_status = vms.list_virtual_machines.find{ |vm| vm.vm_name == instance.name }.status) != "ReadyRole")
	  info("Waiting for VM to be ready. Current state: #{vm_status}")
	  sleep 10
	end
	
	wait_for_sshd(state[:hostname], config[:username], { :port => config[:port] })
	
      end

      def destroy(state)
	return unless state[:hostname]
	vms = Azure::VirtualMachineManagementService.new
	vms.delete_virtual_machine(state[:vm_name], state[:cloud_service])
	FileUtils.rm_r(azure_temp_dir)
      end
      
      private
      
      def azure_temp_dir
	@az_tmp_dir ||= File.join(
	  config[:kitchen_root], %w{.kitchen kitchen-azure}, instance.name
	)
      end
      
      def cert_dir
	@cert_dir ||= File.join(azure_temp_dir, ".ssh")
      end
      
      def generate_ssh_certs
	if File.exists?(File.join(cert_dir, "azure.key")) && File.exists?(File.join(cert_dir , "azure.pem"))
	  debug("certificate files already exist")
	  return
	end
	
	FileUtils.mkdir_p(cert_dir)
	FileUtils.chmod(0700, cert_dir)
	key = OpenSSL::PKey::RSA.new 2048
	cert = OpenSSL::X509::Certificate.new
	cert.version = 2
	cert.serial = 0
	cert.not_before = Time.now
	cert.not_after = Time.now + 3600
	cert.public_key = key.public_key
	
	open(cert_dir + "/azure.key","w",0600) { |io| io.write(key.to_pem) }
	open(cert_dir + "/azure.pem","w",0600) { |io| io.write(cert.to_pem) }
      end
      
    end
  end
end
