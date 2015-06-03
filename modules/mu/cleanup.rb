# Copyright:: Copyright (c) 2014 eGlobalTech, Inc., all rights reserved
#
# Licensed under the BSD-3 license (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License in the root of the project or at
#
#	  http://egt-labs.com/mu/LICENSE.html
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'json'
require 'net/http'
require 'net/smtp'
require 'trollop'
require 'fileutils'

Thread.abort_on_exception = true

module MU

	# Routines for removing cloud resources.
	class Cleanup

		home = Etc.getpwuid(Process.uid).dir
		@knife ="env -i HOME=#{home} CHEF_PUBLIC_IP=#{MU.mu_public_ip} PATH=/opt/chef/embedded/bin:/usr/bin:/usr/sbin knife"

		@muid = nil
		@noop = false
		@force = false
		@onlycloud = false
		@threads = []


		# Expunge Chef resources associated with a node.
		# @param node [String]: The Mu name of the node in question.
		def self.purge_chef_resources(node, vaults_to_clean = nil)
			MU.log "Deleting Chef resources associated with #{node}"
			if !vaults_to_clean.nil?
				vaults_to_clean.each { |vault|
					MU::MommaCat.lock("vault-"+vault['vault'], false, true)
					MU.log "knife vault remove #{vault['vault']} #{vault['item']} --search name:#{node}", MU::NOTICE
					puts `#{MU::Config.knife} vault remove #{vault['vault']} #{vault['item']} --search name:#{node}` if !@noop
					MU::MommaCat.unlock("vault-"+vault['vault'])
				}
			end
			MU.log "knife node delete -y #{node}"
			`#{MU::Config.knife} node delete -y #{node}` if !@noop
			MU.log "knife client delete -y #{node}"
			`#{MU::Config.knife} client delete -y #{node}` if !@noop
			MU.log "knife data bag delete -y #{node}"
			`#{MU::Config.knife} data bag delete -y #{node}` if !@noop
			["crt", "key"].each { |ext|
				if File.exists?("#{MU.mySSLDir}/#{node}.#{ext}")
					MU.log "Removing #{MU.mySSLDir}/#{node}.#{ext}"
					File.unlink("#{MU.mySSLDir}/#{node}.#{ext}") if !@noop
				end
			}
		end

		# Destroy a volume.
		# @param volume [OpenStruct]: The cloud provider's description of the volume.
		# @param id [String]: The cloud provider's identifier for the volume, to use if the full description is not available.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.delete_volume(volume, id: id, region: MU.curRegion)
			if !volume.nil?
				resp = MU.ec2(region).describe_volumes(volume_ids: [volume.volume_id])
				volume = resp.data.volumes.first
			end
			name = ""
			volume.tags.each { |tag|
				name = tag.value if tag.key == "Name"
			}

			MU.log("Deleting volume #{volume.volume_id} (#{name})")
			if !@noop
				if !@skipsnapshots
					if !name.nil? and !name.empty?
							desc = "#{MU.mu_id}-MUfinal (#{name})"
					else
							desc = "#{MU.mu_id}-MUfinal"
					end

					MU.ec2(region).create_snapshot(
						volume_id: volume.volume_id,
						description: desc
					)
				end

				retries = 0
				begin
					MU.ec2(region).delete_volume(volume_id: volume.volume_id)
				rescue Aws::EC2::Errors::RequestLimitExceeded
					sleep 10
					retry
				rescue Aws::EC2::Errors::InvalidVolumeNotFound
					MU.log "Volume #{volume.volume_id} (#{name}) disappeared before I could remove it!", MU::WARN
				rescue Aws::EC2::Errors::VolumeInUse
					if retries < 10
						volume.attachments.each { |attachment|
# TODO @force should rip this away from its mommy
							MU.log "#{volume.volume_id} is attached to #{attachment.instance_id} as #{attachment.device}", MU::NOTICE
						}
						MU.log "Volume '#{name}' is still attached, waiting...", MU::NOTICE
						sleep 30
						retries = retries + 1
						retry
					else
						MU.log "Failed to delete #{name}", MU::ERR
					end
				end
			end
		end

		# Terminate an instance.
		# @param instance [OpenStruct]: The cloud provider's description of the instance.
		# @param id [String]: The cloud provider's identifier for the instance, to use if the full description is not available.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.terminate_instance(instance=nil, id: id, onlylocal: false, region: MU.curRegion)
			ips = Array.new
			if !instance
				if id
					begin
						resp = MU.ec2(region).describe_instances(instance_ids: [id])
					rescue Aws::EC2::Errors::InvalidInstanceIDNotFound => e
						MU.log "Instance #{id} no longer exists", MU::WARN
					end
					if !resp.nil? and !resp.reservations.nil? and !resp.reservations.first.nil?
						instance = resp.reservations.first.instances.first
						ips << instance.public_ip_address if !instance.public_ip_address.nil?
						ips << instance.private_ip_address if !instance.private_ip_address.nil?
					end
				else
					MU.log "You must supply an instance handle or id to terminate_instance", MU::ERR
				end
			else
				id = instance.instance_id
			end
			if !MU.mu_id.empty?
				deploy_dir = File.expand_path("#{MU.dataDir}/deployments/"+MU.mu_id)
				if Dir.exist?(deploy_dir) and !@noop
					FileUtils.touch("#{deploy_dir}/.cleanup-"+id)
				end
			end

			# Remove Chef-related resources and deployment metadata for this instance
			if !@onlycloud
				cleaned_dns = false
				mu_zone, junk = MU::DNSZone.find(name: "mu")
				if !mu_zone.nil?
					dns_targets = []
					rrsets = MU.route53(region).list_resource_record_sets(hosted_zone_id: mu_zone.id)
				end
				begin
					junk, mu_name = MU::Server.find(id: id, region: region)
				rescue Aws::EC2::Errors::InvalidInstanceIDNotFound => e
#					MU.log "Instance #{id} no longer exists", MU::WARN
				end
				servers = MU::MommaCat.getResourceDeployStruct(MU::Server.cfg_plural, name: mu_name, deploy_id: MU.mu_id)

				if servers.is_a?(Array)
					server_hash = {}
					servers.each { |chunk|
						chunk.each { |node_name, data|
							server_hash[node_name] = data.dup
						}
					}
					servers = server_hash
				end

				if !servers.nil? and !servers.is_a?(Array)
					servers.each_pair { |node_name, data|
						if data['instance_id'] == id
							if !rrsets.nil?
								rrsets.resource_record_sets.each { |rrset|
									if rrset.name.match(/^#{node_name.downcase}\.server\.#{MU.myInstanceId}\.mu/i)
										rrset.resource_records.each { |record|
											MU::DNSZone.genericDNSEntry(node_name, record.value, MU::Server, delete: true)
											cleaned_dns = true
										}
									end
								}
							end
							MU::Cleanup.purge_chef_resources(node_name, data['vault_access'])
							if !@noop
								# XXX this doesn't actually work right now (vault bug?) and is
								# tremendously slow.
#								MU::MommaCat.lock("vault-rotate", false, true)
#								MU.log "Rotating vault keys and purging unknown clients"
#								`#{MU::Config.knife} vault rotate all keys --clean-unknown-clients #{MU::Config.vault_opts}`
#								MU::MommaCat.unlock("vault-rotate")
							end
							@mommacat.notify(MU::Server.cfg_plural, mu_name, node_name, remove: true, sub_key: node_name) if !@noop and @mommacat
							break
						end
					}
				end
				# If we didn't manage to find this instance's Route53 entry by sifting
				# deployment metadata, see if we can get it with the Name tag.
				if !mu_zone.nil? and !cleaned_dns and !instance.nil?
					instance.tags.each { |tag|
						if tag.key == "Name"
							rrsets.resource_record_sets.each { |rrset|
								if rrset.name.match(/^#{tag.value.downcase}\.server\.#{MU.myInstanceId}\.mu/i)
									rrset.resource_records.each { |record|
										MU::DNSZone.genericDNSEntry(tag.value, record.value, MU::Server, delete: true)
									}
								end
							}
						end
					}
				end
			end

			if ips.size > 0 and !@onlycloud
				known_hosts_files = [Etc.getpwuid(Process.uid).dir+"/.ssh/known_hosts"] 
				if Etc.getpwuid(Process.uid).name == "root"
					known_hosts_files << Etc.getpwnam("nagios").dir+"/.ssh/known_hosts"
				end
				known_hosts_files.each { |known_hosts|
					next if !File.exists?(known_hosts)
					MU.log "Cleaning up #{ips} from #{known_hosts}"
					if !@noop 
						File.open(known_hosts, File::CREAT|File::RDWR, 0644) { |f|
							f.flock(File::LOCK_EX)
							newlines = Array.new
							f.readlines.each { |line|
								ip_match = false
								ips.each { |ip|
									if line.match(/(^|,| )#{ip}( |,)/)
										MU.log "Expunging #{ip} from #{known_hosts}"
										ip_match = true
									end
								}
								newlines << line if !ip_match
							}
							f.rewind
							f.truncate(0)
							f.puts(newlines)
							f.flush
							f.flock(File::LOCK_UN)
						}
					end
				}
			end


			return if instance.nil? or onlylocal

			name = ""
			instance.tags.each { |tag|
				name = tag.value if tag.key == "Name"
			}

			if instance.state.name == "terminated"
				MU.log "#{instance.instance_id} (#{name}) has already been terminated, skipping"
			else
				if instance.state.name == "terminating"
					MU.log "#{instance.instance_id} (#{name}) already terminating, waiting"
				elsif instance.state.name != "running" and instance.state.name != "pending" and instance.state.name != "stopping" and instance.state.name != "stopped"
					MU.log "#{instance.instance_id} (#{name}) is in state #{instance.state.name}, waiting"
				else
					MU.log "Terminating #{instance.instance_id} (#{name})"
					if !@noop
						begin
							MU.ec2(region).modify_instance_attribute(
								instance_id: instance.instance_id,
								disable_api_termination: { value: false }
							)
							MU.ec2(region).terminate_instances(instance_ids: [instance.instance_id])
							# Small race window here with the state changing from under us
						rescue Aws::EC2::Errors::RequestLimitExceeded
							sleep 10
							retry
						rescue Aws::EC2::Errors::IncorrectInstanceState => e
							resp = MU.ec2(region).describe_instances(instance_ids: [id])
							if !resp.nil? and !resp.reservations.nil? and !resp.reservations.first.nil?
								instance = resp.reservations.first.instances.first
								if !instance.nil? and instance.state.name != "terminated" and instance.state.name != "terminating"
									sleep 5
									retry
								end
							end
						rescue Aws::EC2::Errors::InternalError => e
							MU.log "Error #{e.inspect} while Terminating instance #{instance.instance_id} (#{name}), retrying", MU::WARN, details: e.inspect
							sleep 5
							retry
						end
					end
				end
				while instance.state.name != "terminated" and !@noop
					sleep 30
					instance_response = MU.ec2(region).describe_instances(instance_ids: [instance.instance_id])
					instance = instance_response.reservations.first.instances.first
				end
				MU.log "#{instance.instance_id} (#{name}) terminated" if !@noop
			end
		end


		# Remove all instances associated with the currently loaded deployment. Also cleans up associated volumes, droppings in the MU master's /etc/hosts and ~/.ssh, and in Chef.
		# @param region [String]: The cloud provider region
		# @return [Integer]: The number of instances terminated.
		def self.purge_ec2(region: MU.curRegion)
			instances = Array.new
			unterminated = Array.new

			# Build a list of instances we need to clean up. We guard against
			# accidental deletion here by requiring someone to have hand-terminated
			# these, by default.
			resp = MU.ec2(region).describe_instances(
				filters: @stdfilters
			)

			return if resp.data.reservations.nil?
			resp.data.reservations.each { |reservation|
				reservation.instances.each { |instance|
				  if instance.state.name != "terminated" and !@force and !@noop
					unterminated << instance
				  else
					instances << instance
				  end
				}
			}

			if unterminated.size > 0 and !@force and !@noop then
				MU.log "Unterminated instances exist for this stack, aborting!"
				MU.log "Terminate the following by hand, or use -f."
				unterminated.each { |instance|
					name = ""
					instance.tags.each { |tag|
						name = tag.value if tag.key == "Name"
					}
					MU.log "\t#{name} (#{instance.instance_id})"
				}
				exit 1
			end

			parent_thread_id = Thread.current.object_id

			instances.each { |instance|
			@threads << Thread.new(instance) do |myinstance|
					MU.dupGlobals(parent_thread_id)
			  Thread.abort_on_exception = true
					terminate_instance(id: myinstance.instance_id, region: region)
				end
			}


			resp = MU.ec2(region).describe_volumes(
				filters: @stdfilters
			)
			resp.data.volumes.each { |volume|
			@threads << Thread.new(volume) do |myvolume|
					MU.dupGlobals(parent_thread_id)
					delete_volume(myvolume)
				end
			}

			# Wait for all of the instances to finish cleanup before proceeding
			@threads.each do |t|
				t.join
			end
			return instances.size
		end

		# Remove all network gateways associated with the currently loaded deployment.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.purge_gateways(region: MU.curRegion)
			resp = MU.ec2(region).describe_internet_gateways(
				filters: @stdfilters
			)
			gateways = resp.data.internet_gateways

			gateways.each { |gateway|
				gateway.attachments.each { |attachment|
					MU.log "Detaching Internet Gateway #{gateway.internet_gateway_id} from #{attachment.vpc_id}"
					begin
						MU.ec2(region).detach_internet_gateway(
							internet_gateway_id: gateway.internet_gateway_id,
							vpc_id: attachment.vpc_id
						)
					rescue Aws::EC2::Errors::GatewayNotAttached => e
						MU.log "Gateway #{gateway.internet_gateway_id} was already detached", MU::WARN
					end
				}
				MU.log "Deleting Internet Gateway #{gateway.internet_gateway_id}"
				MU.ec2(region).delete_internet_gateway(internet_gateway_id: gateway.internet_gateway_id)
			}
			return nil
		end

		# Remove all route tables associated with the currently loaded deployment.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.purge_routetables(region: MU.curRegion)
			resp = MU.ec2(region).describe_route_tables(
				filters: @stdfilters
			)
			route_tables = resp.data.route_tables

			return if route_tables.nil? or route_tables.size == 0

			route_tables.each { |table|
				table.routes.each { |route|
					if !route.network_interface_id.nil?
						MU.log "Deleting Network Interface #{route.network_interface_id}"
						begin
							MU.ec2(region).delete_network_interface(network_interface_id: route.network_interface_id)
						rescue Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound => e
							MU.log "Network Interface #{route.network_interface_id} has already been deleted", MU::WARN
						end
					end
					if route.gateway_id != "local"
						MU.log "Deleting #{table.route_table_id}'s route for #{route.destination_cidr_block}"
						MU.ec2(region).delete_route(
							route_table_id: table.route_table_id,
							destination_cidr_block: route.destination_cidr_block
						)
					end
				}
				can_delete = true
				table.associations.each { |assoc|
					begin
						MU.ec2(region).disassociate_route_table(association_id: assoc.route_table_association_id)
					rescue Aws::EC2::Errors::InvalidAssociationIDNotFound => e
						MU.log "Route table association #{assoc.route_table_association_id} already removed", MU::WARN
					rescue Aws::EC2::Errors::InvalidParameterValue => e
						# normal and ignorable with the default route table
						can_delete = false
						next
					end
				}
				next if !can_delete
				MU.log "Deleting Route Table #{table.route_table_id}"
				MU.ec2(region).delete_route_table(route_table_id: table.route_table_id)
			}
			return nil
		end


		# Remove all network interfaces associated with the currently loaded deployment.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.purge_interfaces(region: MU.curRegion)
			resp = MU.ec2(region).describe_network_interfaces(
				filters: @stdfilters
			)
			ifaces = resp.data.network_interfaces

			return if ifaces.nil? or ifaces.size == 0

			ifaces.each { |iface|
				MU.log "Deleting Network Interface #{iface.network_interface_id}"
				MU.ec2(region).delete_network_interface(network_interface_id: iface.network_interface_id)
			}
		end

		# Remove all subnets associated with the currently loaded deployment.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.purge_subnets(region: MU.curRegion)
			resp = MU.ec2(region).describe_subnets(
				filters: @stdfilters
			)
			subnets = resp.data.subnets

			return if subnets.nil? or subnets.size == 0

			subnets.each { |subnet|
				begin
					if subnet.state != "available"
						MU.log "Waiting for #{subnet.subnet_id} to be in a removable state...", MU::NOTICE
						sleep 30
					else
						MU.log "Deleting Subnet #{subnet.subnet_id}"
						MU.ec2(region).delete_subnet(subnet_id: subnet.subnet_id)
					end
				rescue Aws::EC2::Errors::InvalidSubnetIDNotFound
					MU.log "Subnet #{subnet.subnet_id} disappeared before I could remove it", MU::WARN
					next
				end while subnet.state != "available"
			}
		end

		# Remove all DHCP options sets associated with the currently loaded
		# deployment.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.purge_dhcpopts(region: MU.curRegion)
			resp = MU.ec2(region).describe_dhcp_options(
				filters: @stdfilters
			)
			sets = resp.data.dhcp_options

			return if sets.nil? or sets.size == 0

			sets.each { |optset|
				begin
					MU.log "Deleting DHCP Option Set #{optset.dhcp_options_id}"
					MU.ec2(region).delete_dhcp_options(dhcp_options_id: optset.dhcp_options_id)
				rescue Aws::EC2::Errors::DependencyViolation => e
					MU.log e.inspect, MU::ERR
#				rescue Aws::EC2::Errors::InvalidSubnetIDNotFound
#					MU.log "Subnet #{subnet.subnet_id} disappeared before I could remove it", MU::WARN
#					next
				end
			}
		end

		# Remove all VPCs associated with the currently loaded deployment.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.purge_vpcs(region: MU.curRegion)
			resp = MU.ec2(region).describe_vpcs(
				filters: @stdfilters
			)

			vpcs = resp.data.vpcs
			return if vpcs.nil? or vpcs.size == 0

			vpcs.each { |vpc|
				my_peer_conns = MU.ec2(region).describe_vpc_peering_connections(
					filters: [
						{
							name: "requester-vpc-info.vpc-id",
							values: [vpc.vpc_id]
						}
					]
				).vpc_peering_connections
				my_peer_conns.concat(MU.ec2(region).describe_vpc_peering_connections(
					filters: [
						{
							name: "accepter-vpc-info.vpc-id",
							values: [vpc.vpc_id]
						}
					]
				).vpc_peering_connections)
				my_peer_conns.each { |cnxn|
					
					[cnxn.accepter_vpc_info.vpc_id, cnxn.requester_vpc_info.vpc_id].each { |peer_vpc|
						MU::VPC.listAllSubnetRouteTables(peer_vpc, region: region).each { |rtb_id|
							resp = MU.ec2(region).describe_route_tables(
								route_table_ids: [rtb_id]
							)
							resp.route_tables.each { |rtb|
								rtb.routes.each { |route|
									if route.vpc_peering_connection_id == cnxn.vpc_peering_connection_id
										MU.log "Removing route #{route.destination_cidr_block} from route table #{rtb_id} in VPC #{peer_vpc}"
										MU.ec2(region).delete_route(
											route_table_id: rtb_id,
											destination_cidr_block: route.destination_cidr_block
										) if !@noop
									end
								}
							}
						}
					}
					MU.log "Deleting VPC peering connection #{cnxn.vpc_peering_connection_id}"
					begin
						MU.ec2(region).delete_vpc_peering_connection(
							vpc_peering_connection_id: cnxn.vpc_peering_connection_id
						) if !@noop
					rescue Aws::EC2::Errors::InvalidStateTransition => e
						MU.log "VPC peering connection #{cnxn.vpc_peering_connection_id} not in removable (state #{cnxn.status.code})", MU::WARN
					end
				}
				
				MU.log "Deleting VPC #{vpc.vpc_id}"
				begin
					MU.ec2(region).delete_vpc(vpc_id: vpc.vpc_id)
				rescue Aws::EC2::Errors::DependencyViolation => e
					MU.log "Couldn't delete VPC #{vpc.vpc_id}: #{e.inspect}", MU::ERR
				end

				mu_zone, junk = MU::DNSZone.find(name: "mu", region: region)
				if !mu_zone.nil?
					MU::DNSZone.toggleVPCAccess(id: mu_zone.id, vpc_id: vpc.vpc_id, remove: true)
				end

			}
		end

		# Remove all security groups (firewall rulesets) associated with the currently loaded deployment.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.purge_secgroups(region: MU.curRegion)

			resp = MU.ec2(region).describe_security_groups(
				filters: @stdfilters
			)

			resp.data.security_groups.each { |sg|
				MU.log "Revoking rules in EC2 Security Group #{sg.group_name} (#{sg.group_id})"

				if !@noop
					ingress_to_revoke = Array.new
					egress_to_revoke = Array.new
					sg.ip_permissions.each { |hole|

						hole_hash = MU.structToHash(hole)
						if !hole_hash[:user_id_group_pairs].nil?
							hole[:user_id_group_pairs].each { |group_ref|
								group_ref.delete(:group_name) if group_ref.is_a?(Hash)
							}
						end
						ingress_to_revoke << MU.structToHash(hole)
						ingress_to_revoke.each { |rule|
							if !rule[:user_id_group_pairs].nil? and rule[:user_id_group_pairs].size == 0
								rule.delete(:user_id_group_pairs)
							end
							if !rule[:ip_ranges].nil? and rule[:ip_ranges].size == 0
								rule.delete(:ip_ranges)
							end
							if !rule[:prefix_list_ids].nil? and rule[:prefix_list_ids].size == 0
								rule.delete(:prefix_list_ids)
							end
						}
					}
					sg.ip_permissions_egress.each { |hole|
						hole_hash = MU.structToHash(hole)
						if !hole_hash[:user_id_group_pairs].nil? and hole_hash[:user_id_group_pairs].is_a?(Hash)
							hole[:user_id_group_pairs].each { |group_ref|
								group_ref.delete(:group_name)
							}
						end
						egress_to_revoke << MU.structToHash(hole)
						egress_to_revoke.each { |rule|
							if !rule[:user_id_group_pairs].nil? and rule[:user_id_group_pairs].size == 0
								rule.delete(:user_id_group_pairs)
							end
							if !rule[:ip_ranges].nil? and rule[:ip_ranges].size == 0
								rule.delete(:ip_ranges)
							end
							if !rule[:prefix_list_ids].nil? and rule[:prefix_list_ids].size == 0
								rule.delete(:prefix_list_ids)
							end
						}
					}
					begin
						if ingress_to_revoke.size > 0
							MU.ec2(region).revoke_security_group_ingress(
								group_id: sg.group_id,
								ip_permissions: ingress_to_revoke
							)
						end
						if egress_to_revoke.size > 0
							MU.ec2(region).revoke_security_group_egress(
								group_id: sg.group_id,
								ip_permissions: egress_to_revoke
							)
						end
					rescue Aws::EC2::Errors::InvalidPermissionNotFound
						MU.log "Rule in #{sg.group_id} disappeared before I could remove it", MU::WARN
					end
				end
			}

			resp.data.security_groups.each { |sg|
				MU.log "Removing EC2 Security Group #{sg.group_name}"

				retries = 0
				begin
				  MU.ec2(region).delete_security_group(group_id: sg.group_id) if !@noop
				rescue Aws::EC2::Errors::InvalidGroupNotFound
					MU.log "EC2 Security Group #{sg.group_name} disappeared before I could delete it!", MU::WARN
				rescue Aws::EC2::Errors::DependencyViolation, Aws::EC2::Errors::InvalidGroupInUse
					if retries < 10
						MU.log "EC2 Security Group #{sg.group_name} is still in use, waiting...", MU::NOTICE
						sleep 10
						retries = retries + 1
						retry
					else
						MU.log "Failed to delete #{sg.group_name}", MU::ERR
					end
				end
			}
		end

		# Purge all resources associated with a deployment.
		# @param muid [String]: The identifier of the deployment to remove (typically seen in the MU-ID tag on a resource).
		# @param force [Boolean]: Force deletion of resources.
		# @param noop [Boolean]: Do not delete resources, merely list what would be deleted.
		# @param skipsnapshots [Boolean]: Refrain from saving final snapshots of volumes and databases before deletion.
		# @param onlycloud [Boolean]: Purge cloud resources, but skip purging all Mu master metadata, ssh keys, etc.
		# @param verbose [Boolean]: Generate verbose output.
		# @param web [Boolean]: Generate web-friendly output.
		# @param ignoremaster [Boolean]: Ignore the tags indicating the originating MU master server when deleting.
		# @return [void]
		def self.run(muid, force, noop=false, skipsnapshots=false, onlycloud=false, verbose=false, web=false, ignoremaster=false, mommacat: nil)
			MU.setLogging(verbose, web)
			@noop = noop
			@skipsnapshots = skipsnapshots
			@force = force
			@onlycloud = onlycloud
			@ignoremaster = ignoremaster

			if MU.chef_user != "mu"
				MU.setVar("dataDir", Etc.getpwnam(MU.chef_user).dir+"/.mu/var")
			else
				MU.setVar("dataDir", MU.mainDataDir)
			end

			# Load up our deployment metadata
			if !mommacat.nil?
				@mommacat = mommacat
			else
				begin
					deploy_dir = File.expand_path("#{MU.dataDir}/deployments/"+muid)
					if Dir.exist?(deploy_dir)
#						key = OpenSSL::PKey::RSA.new(File.read("#{deploy_dir}/public_key"))
#						deploy_secret = key.public_encrypt(File.read("#{deploy_dir}/deploy_secret"))
						FileUtils.touch("#{deploy_dir}/.cleanup") if !@noop
					else
						MU.log "I don't see a deploy named #{muid}.", MU::WARN
						MU.log "Known deployments:\n#{Dir.entries(deploy_dir).reject{|item| item.match(/^\./) or !File.exists?(deploy_dir+"/"+item+"/public_key") }.join("\n")}", MU::WARN
						if !@force
							MU.log "Use -f to proceed anyway and search for remnants of #{muid}.", MU::WARN
							exit 1
						else
							MU.log "Searching for remnants of #{muid}, though this may be an invalid MU-ID.", MU::WARN
						end
					end
					@mommacat = MU::MommaCat.new(muid)
				rescue Exception => e
					MU.log "Can't load a deploy record for #{muid} (#{e.inspect}), cleaning up resources by guesswork", MU::WARN, details: e.backtrace
					MU.setVar("mu_id", muid)
				end
			end

			# We identify most taggable resources like this.
			@stdfilters = [
				{ name: "tag:MU-ID", values: [MU.mu_id] }
			]
			if !@ignoremaster
				@stdfilters << { name: "tag:MU-MASTER-IP", values: [MU.mu_public_ip] }
			end
			parent_thread_id = Thread.current.object_id


			regions = MU::Config.listRegions
			deleted_nodes = 0
			@regionthreads = []
			regions.each { |r|
				@regionthreads << Thread.new {
					MU.dupGlobals(parent_thread_id)
					MU.setVar("curRegion", r)
					MU.log "Checking for cloud resources in #{r}", MU::NOTICE
					begin
						MU::CloudFormation.cleanup(@noop, @ignoremaster, region: r)
						MU::ServerPool.cleanup(@noop, @ignoremaster, region: r)
						MU::LoadBalancer.cleanup(@noop, @ignoremaster, region: r)
						deleted_nodes = purge_ec2(region: r) + deleted_nodes
						MU::Database.cleanup(@noop, @ignoremaster, region: r)
						purge_secgroups(region: r)
						purge_gateways(region: r)
						MU::DNSZone.cleanup(@noop, region: r)
						purge_routetables(region: r)
						purge_interfaces(region: r)
						purge_subnets(region: r)
						purge_vpcs(region: r)
						purge_dhcpopts(region: r)

						# Hit CloudFormation again- sometimes the first delete will quietly
						# fail due to dependencies.
						MU::CloudFormation.cleanup(@noop, wait: true, region: r)
					rescue Aws::EC2::Errors::RequestLimitExceeded, Aws::EC2::Errors::Unavailable, Aws::EC2::Errors::InternalError => e
						MU.log e.inspect, MU::WARN
						sleep 30
						retry
					end
				}
			}

			@regionthreads.each do |t|
				t.join
			end
			@threads = []

			vaults_to_clean = []
			if !@mommacat.nil? and !@mommacat.original_config.nil?
				if !@mommacat.original_config["servers"].nil?
					@mommacat.original_config["servers"].each { |server|
						begin
							MU::Server.removeIAMProfile("Server-"+server['name']) if !@noop
						rescue Exception => e
							MU.log e.inspect, MU::NOTICE
						end
						if !server['vault_access'].nil?
							server['vault_access'].each { |vault|
								vaults_to_clean << vault
							}
						end
					}
				end
				if !@mommacat.original_config["server_pools"].nil?
					@mommacat.original_config["server_pools"].each { |server|
						begin
							if !@noop
								MU::Server.removeIAMProfile("ServerPool-"+server['name'])
							end
						rescue Exception => e
							MU.log e.inspect, MU::NOTICE
						end
						if !server['vault_access'].nil?
							server['vault_access'].each { |vault|
								vaults_to_clean << vault
							}
						end
					}
				end
			end
			vaults_to_clean.uniq!

			@threads.each do |t|
				t.join
			end
			@threads = []

			if !@onlycloud
				parent_thread_id = Thread.current.object_id

				chef_nodes = `#{MU::Config.knife} node list`.split("\n")
				chef_nodes.each { |node|
					@threads << Thread.new {
						MU.dupGlobals(parent_thread_id)
						if node.match(/^#{MU.mu_id}\-.+$/) then
							MU::Cleanup.purge_chef_resources(node)
						end
					}
				}

				@mommacat.purge! if @mommacat and !@noop
			end

			if !@noop and vaults_to_clean.size > 0
				# XXX we actually want a global vault lock here, I suppose
				MU.log "#{MU::Config.knife} vault rotate all keys --clean-unknown-clients #{MU::Config.vault_opts}"
				MU::MommaCat.lock("vault-cleanup", false, true)
				`#{MU::Config.knife} vault rotate all keys --clean-unknown-clients #{MU::Config.vault_opts}`
				MU::MommaCat.unlock("vault-cleanup")
			end

			keyname = "deploy-#{MU.mu_id}"
			begin
				regions = MU::Config.listRegions
				regions.each { |r|
					resp = MU.ec2(r).describe_key_pairs(
						filters: [
							{ name: "key-name", values: [keyname] }
						]
					)
					resp.data.key_pairs.each { |keypair|
						MU.log "Deleting key pair #{keypair.key_name} from #{r}"
						MU.ec2(r).delete_key_pair(key_name: keypair.key_name) if !@noop
					}
				}
			rescue Aws::EC2::Errors::RequestLimitExceeded, Aws::EC2::Errors::Unavailable, Aws::EC2::Errors::InternalError => e
				MU.log e.inspect, MU::WARN
				sleep 30
				retry
			end

			exit if @onlycloud

			myhome = Etc.getpwuid(Process.uid).dir
			sshdir = "#{myhome}/.ssh"
			sshconf = "#{sshdir}/config"
			ssharchive = "#{sshdir}/archive"
			
			Dir.mkdir(sshdir, 0700) if !Dir.exists?(sshdir) and !@noop
			Dir.mkdir(ssharchive, 0700) if !Dir.exists?(ssharchive) and !@noop
			
			keyname = "deploy-#{MU.mu_id}"
			if File.exists?("#{sshdir}/#{keyname}")
				MU.log "Moving #{sshdir}/#{keyname} to #{ssharchive}/#{keyname}"
				if !@noop
					File.rename("#{sshdir}/#{keyname}", "#{ssharchive}/#{keyname}")
				end
			end
			
			if File.exists?(sshconf) and File.open(sshconf).read.match(/\/deploy\-#{MU.mu_id}$/)
				MU.log "Expunging #{MU.mu_id} from #{sshconf}"
				if !@noop 
					FileUtils.copy(sshconf, "#{ssharchive}/config-#{MU.mu_id}")
					File.open(sshconf, File::CREAT|File::RDWR, 0600) { |f|
						f.flock(File::LOCK_EX)
						newlines = Array.new
						delete_block = false
						f.readlines.each { |line|
							if line.match(/^Host #{MU.mu_id}\-/)
								delete_block = true
							elsif line.match(/^Host /)
								delete_block = false
							end
							newlines << line if !delete_block
						}
						f.rewind
						f.truncate(0)
						f.puts(newlines)
						f.flush
						f.flock(File::LOCK_UN)
					}
				end
			end
			
			# XXX refactor with above? They're similar, ish.
			hostsfile = "/etc/hosts"
			if File.open(hostsfile).read.match(/ #{MU.mu_id}\-/)
				MU.log "Expunging traces of #{MU.mu_id} from #{hostsfile}"
				if !@noop 
					FileUtils.copy(hostsfile, "#{hostsfile}.cleanup-#{muid}")
					File.open(hostsfile, File::CREAT|File::RDWR, 0644) { |f|
						f.flock(File::LOCK_EX)
						newlines = Array.new
						f.readlines.each { |line|
							newlines << line if !line.match(/ #{MU.mu_id}\-/)
						}
						f.rewind
						f.truncate(0)
						f.puts(newlines)
						f.flush
						f.flock(File::LOCK_UN)
					}
				end
			end

			if !@noop
				MU.s3(MU.myRegion).delete_object(
					bucket: MU.adminBucketName,
					key: "#{MU.mu_id}-secret"
				)
			end


			@threads.each do |t|
				t.join
			end

			@mommacat.purge! if @mommacat and !@noop
			if deleted_nodes > 0
				MU::MommaCat.syncMonitoringConfig if !@noop
			end

		end

	end #class
end #module
