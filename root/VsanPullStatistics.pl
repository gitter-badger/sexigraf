#!/usr/bin/perl -w
#

use strict;
use warnings;
use VMware::VIRuntime;
use VMware::VICredStore;
use JSON;
use Data::Dumper;
use Net::Graphite;
use Log::Log4perl qw(:easy);

$Data::Dumper::Indent = 1;
$Util::script_version = "0.9.11";
$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

Opts::parse();
Opts::validate();

my $url = Opts::get_option('url');
my $vcenterserver = Opts::get_option('server');
my $username = Opts::get_option('username');
my $password = Opts::get_option('password');
my $sessionfile = Opts::get_option('sessionfile');
my $credstorefile = Opts::get_option('credstore');

my $exec_start = time;
my $logger = Log::Log4perl->get_logger('sexigraf.VsanDisksPullStatistics');
VMware::VICredStore::init (filename => $credstorefile) or $logger->logdie ("[ERROR] Unable to initialize Credential Store.");
my @user_list = VMware::VICredStore::get_usernames (server => $vcenterserver);

# set graphite target
my $graphite = Net::Graphite->new(
	# except for host, these hopefully have reasonable defaults, so are optional
	host                  => '127.0.0.1',
	port                  => 2003,
	trace                 => 0,                # if true, copy what's sent to STDERR
	proto                 => 'tcp',            # can be 'udp'
	timeout               => 1,                # timeout of socket connect in seconds
	fire_and_forget       => 1,                # if true, ignore sending errors
	return_connect_error  => 0,                # if true, forward connect error to caller
);

BEGIN {
        Log::Log4perl::init('/etc/log4perl.conf');
	$SIG{__WARN__} = sub {
		   my $logger = get_logger('sexigraf.VsanDisksPullStatistics');
		   local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
		   $logger->warn("WARN @_");
	   };		
	$SIG{__DIE__} = sub {
		   my $logger = get_logger('sexigraf.VsanDisksPullStatistics');
		   local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
		   $logger->fatal("DIE @_");
	   };
}

$logger->info("[INFO] Start processing vCenter $vcenterserver");

# handling sessionfile if missing or expired
if (scalar @user_list == 0) {
	$logger->logdie ("[ERROR] No credential store user detected for $vcenterserver");
} elsif (scalar @user_list > 1) {
	$logger->logdie ("[ERROR] Multiple credential store user detected for $vcenterserver");
} else {
	foreach my $username (@user_list) {
		$logger->info("[INFO] Login to vCenter $vcenterserver");
		$password = VMware::VICredStore::get_password (server => $vcenterserver, username => $username);
		$url = "https://" . $vcenterserver . "/sdk";
		if (defined($sessionfile) and -e $sessionfile) {
			eval { Vim::load_session(service_url => $url, session_file => $sessionfile); };
			if ($@) { Vim::login(service_url => $url, user_name => $username, password => $password) or $logger->logdie ("[ERROR] Unable to connect to $url with username $username"); }
		} else { Vim::login(service_url => $url, user_name => $username, password => $password) or $logger->logdie ("[ERROR] Unable to connect to $url with username $username"); }

		if (defined($sessionfile)) {
			Vim::save_session(session_file => $sessionfile);
			$logger->info("[INFO] vCenter $vcenterserver session file saved");
		}
	}
}

sub getParent {
        my ($parent) = @_;
        if($parent->parent) { getParent($parent->parent); }
	return $parent;
}

# retreive vcenter hostname
my $vcenter_fqdn = $vcenterserver;

$vcenter_fqdn =~ s/[ .]/_/g;
my $vcenter_name = lc ($vcenter_fqdn);

# retreive datacenter(s) list
my $datacentres_views = Vim::find_entity_views(view_type => 'Datacenter', properties => ['name']);

$logger->info("[INFO] Processing vCenter $vcenterserver datacenters");

foreach my $datacentre_view (@$datacentres_views) {	
	my $datacentre_name = lc ($datacentre_view->name);
	$datacentre_name =~ s/[ .]/_/g;
	
	my $clusters_views = Vim::find_entity_views(view_type => 'ClusterComputeResource', properties => ['name','configurationEx', 'summary', 'datastore', 'host'], begin_entity => $datacentre_view);
	
	$logger->info("[INFO] Processing vCenter $vcenterserver clusters");
	
	foreach my $cluster_view (@$clusters_views) {
		my $cluster_name = lc ($cluster_view->name);
		$cluster_name =~ s/[ .]/_/g;
		if($cluster_view->configurationEx->vsanConfigInfo->enabled) {
		
		$logger->info("[INFO] Processing vCenter $vcenterserver VSAN cluster $cluster_name");
		
			my $hosts_views = Vim::find_entity_views(view_type => 'HostSystem', begin_entity => $cluster_view , properties => ['config.network.dnsConfig.hostName','configManager.vsanInternalSystem', 'runtime']);

			my $vm_views_device = Vim::find_entity_views(view_type => 'VirtualMachine', begin_entity => $cluster_view , properties => ['config.hardware.device']);
			my $VirtualDisks = {};
			
			foreach my $vm_view_device (@$vm_views_device) {
				my $vmDevices = $vm_view_device->{'config.hardware.device'};

				foreach(@$vmDevices) {
					if($_->isa('VirtualDisk')) {
											
						my @vmdkpath = split("/", $_->backing->fileName);
						my $vmdk = substr($vmdkpath[-1], 0, -5);
						$vmdk =~ s/[ .()]/_/g;
						$VirtualDisks->{ $_->backing->backingObjectId } = $vmdk;
						
						if ($_->backing->parent) {
							my $rootparent = getParent($_->backing->parent);
							my @rootvmdkpath = split("/", $rootparent->fileName);
							my $rootvmdk = substr($rootvmdkpath[-1], 0, -5);
							$rootvmdk =~ s/[ .()]/_/g;
							$VirtualDisks->{ $_->backing->backingObjectId . "_root"} = $rootparent->backingObjectId;
							$VirtualDisks->{ $rootparent->backingObjectId} = $rootvmdk;
						}
					}
				}
			}
			
			foreach my $host_view (@$hosts_views) {
				
				if ($host_view->runtime->connectionState->val eq "connected") {
				
					my $host_vsan_view = Vim::get_view(mo_ref => $host_view->{'configManager.vsanInternalSystem'});
					
					my $host_vsan_stats = $host_vsan_view->QueryVsanStatistics(labels => ['dom']);
					my $host_vsan_stats_json = from_json($host_vsan_stats);
					
					if ($host_vsan_stats_json) {
						my $host_vsan_stats_json_compmgr = $host_vsan_stats_json->{'dom.compmgr.stats'};
						my $host_vsan_stats_json_client = $host_vsan_stats_json->{'dom.client.stats'};
						my $host_vsan_stats_json_owner = $host_vsan_stats_json->{'dom.owner.stats'};
						my $host_vsan_stats_json_sched = $host_vsan_stats_json->{'dom.compmgr.schedStats'};
						my $host_name = lc ($host_view->{'config.network.dnsConfig.hostName'});

						foreach my $compmgrkey (keys %{ $host_vsan_stats_json_compmgr }) {
							$graphite->send(
							path => "vsan." . "$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.compmgr.stats." . "$compmgrkey",
							value => $host_vsan_stats_json_compmgr->{$compmgrkey},
							time => time(),
							);
						}
						
						foreach my $clientkey (keys %{ $host_vsan_stats_json_client }) {
							$graphite->send(
							path => "vsan." . "$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.client.stats." . "$clientkey",
							value => $host_vsan_stats_json_client->{$clientkey},
							time => time(),
							);
						}
						
						foreach my $ownerkey (keys %{ $host_vsan_stats_json_owner }) {
							$graphite->send(
							path => "vsan." . "$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.owner.stats." . "$ownerkey",
							value => $host_vsan_stats_json_owner->{$ownerkey},
							time => time(),
							);
						}
						
						foreach my $schedkey (keys %{ $host_vsan_stats_json_sched }) {
							$graphite->send(
							path => "vsan." . "$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.compmgr.schedStats." . "$schedkey",
							value => $host_vsan_stats_json_sched->{$schedkey},
							time => time(),
							);
						}
					}
					
					my $host_vsan_lsom = $host_vsan_view->QueryVsanStatistics(labels => ['lsom']);
					my $host_vsan_lsom_json = from_json($host_vsan_lsom);
					
					if ($host_vsan_lsom_json) {
						my $host_vsan_lsom_json_disks = $host_vsan_lsom_json->{'lsom.disks'};
						my $host_name = lc ($host_view->{'config.network.dnsConfig.hostName'});

						foreach my $lsomkey (keys %{ $host_vsan_lsom_json_disks }) {
							if ($host_vsan_lsom_json_disks->{$lsomkey}->{info}->{ssd} ne "NA") {
								my $lsomkeyCapacityUsed = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{capacityUsed};
								my $lsomkeyCapacity = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{capacity};
								my $lsomkeyCapacityUsedPercent = $lsomkeyCapacityUsed * 100 / $lsomkeyCapacity;
								
								my $host_vsan_lsom_json_disks_h = {
									time() => {
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.disks." . "$lsomkey" . ".capacityUsed", $lsomkeyCapacityUsed,
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.disks." . "$lsomkey" . ".capacity", $lsomkeyCapacity,
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.disks." . "$lsomkey" . ".percentUsed", $lsomkeyCapacityUsedPercent,
									},
								};
								$graphite->send(path => "vsan.", data => $host_vsan_lsom_json_disks_h);
							}
							elsif ($host_vsan_lsom_json_disks->{$lsomkey}->{info}->{ssd} eq "NA") {
								my $lsomkeyMiss = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{aggStats}->{miss};
								my $lsomkeyQuotaEvictions = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{aggStats}->{quotaEvictions};
								my $lsomkeyReadIoCount = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{aggStats}->{readIoCount};
								my $lsomkeyWBsize = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{wbSize};
								my $lsomkeyWBfreeSpace = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{wbFreeSpace};
								my $lsomkeyWBwriteIoCount = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{aggStats}->{writeIoCount};
								my $lsomkeyBytesRead = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{aggStats}->{bytesRead};
								my $lsomkeyBytesWritten = $host_vsan_lsom_json_disks->{$lsomkey}->{info}->{aggStats}->{bytesWritten};
								
								my $host_vsan_lsom_json_ssd_h = {
									time() => {
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.ssd." . "$lsomkey" . ".miss", $lsomkeyMiss,
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.ssd." . "$lsomkey" . ".quotaEvictions", $lsomkeyQuotaEvictions,
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.ssd." . "$lsomkey" . ".readIoCount", $lsomkeyReadIoCount,
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.ssd." . "$lsomkey" . ".wbSize", $lsomkeyWBsize,
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.ssd." . "$lsomkey" . ".wbFreeSpace", $lsomkeyWBfreeSpace,
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.ssd." . "$lsomkey" . ".writeIoCount", $lsomkeyWBwriteIoCount,
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.ssd." . "$lsomkey" . ".bytesRead", $lsomkeyBytesRead,
										"$vcenter_name.$datacentre_name.$cluster_name.esx.$host_name" . ".vsan.lsom.ssd." . "$lsomkey" . ".bytesWritten", $lsomkeyBytesWritten,
									},
								};
								$graphite->send(path => "vsan.", data => $host_vsan_lsom_json_ssd_h);
							}
						}
					}

					my $host_vsan_dom_objects = $host_vsan_view->QueryVsanStatistics(labels => ['dom-objects']);
					my $host_vsan_dom_objects_json = from_json($host_vsan_dom_objects);

					if ($host_vsan_dom_objects_json) {
						my $host_vsan_dom_objects_json_stats = $host_vsan_dom_objects_json->{'dom.owners.stats'};
						my $host_name = lc ($host_view->{'config.network.dnsConfig.hostName'});

						foreach my $dom_objects_key (keys %{ $host_vsan_dom_objects_json_stats }) {
							if ($VirtualDisks->{$dom_objects_key}) {
								if ($VirtualDisks->{$dom_objects_key . "_root"}) {
									my $root_dom_objects_key = $VirtualDisks->{$dom_objects_key . "_root"};
									my $host_vsan_dom_objects_json_stats_h_snap = {
										time() => {
											"$vcenter_name.$datacentre_name.$cluster_name" . ".vsan.dom.owners.stats." . "$root_dom_objects_key.$VirtualDisks->{$dom_objects_key}" . ".readCount", $host_vsan_dom_objects_json_stats->{$dom_objects_key}->{readCount},
											"$vcenter_name.$datacentre_name.$cluster_name" . ".vsan.dom.owners.stats." . "$root_dom_objects_key.$VirtualDisks->{$dom_objects_key}" . ".writeCount", $host_vsan_dom_objects_json_stats->{$dom_objects_key}->{writeCount},
											"$vcenter_name.$datacentre_name.$cluster_name" . ".vsan.dom.owners.stats." . "$root_dom_objects_key.$VirtualDisks->{$dom_objects_key}" . ".readBytes", $host_vsan_dom_objects_json_stats->{$dom_objects_key}->{readBytes},
											"$vcenter_name.$datacentre_name.$cluster_name" . ".vsan.dom.owners.stats." . "$root_dom_objects_key.$VirtualDisks->{$dom_objects_key}" . ".writeBytes", $host_vsan_dom_objects_json_stats->{$dom_objects_key}->{writeBytes},
										},
									};
									$graphite->send(path => "vsan.", data => $host_vsan_dom_objects_json_stats_h_snap);
								} else {
									my $host_vsan_dom_objects_json_stats_h = {
										time() => {
											"$vcenter_name.$datacentre_name.$cluster_name" . ".vsan.dom.owners.stats." . "$dom_objects_key.$VirtualDisks->{$dom_objects_key}" . ".readCount", $host_vsan_dom_objects_json_stats->{$dom_objects_key}->{readCount},
											"$vcenter_name.$datacentre_name.$cluster_name" . ".vsan.dom.owners.stats." . "$dom_objects_key.$VirtualDisks->{$dom_objects_key}" . ".writeCount", $host_vsan_dom_objects_json_stats->{$dom_objects_key}->{writeCount},
											"$vcenter_name.$datacentre_name.$cluster_name" . ".vsan.dom.owners.stats." . "$dom_objects_key.$VirtualDisks->{$dom_objects_key}" . ".readBytes", $host_vsan_dom_objects_json_stats->{$dom_objects_key}->{readBytes},
											"$vcenter_name.$datacentre_name.$cluster_name" . ".vsan.dom.owners.stats." . "$dom_objects_key.$VirtualDisks->{$dom_objects_key}" . ".writeBytes", $host_vsan_dom_objects_json_stats->{$dom_objects_key}->{writeBytes},
										},
									};
									$graphite->send(path => "vsan.", data => $host_vsan_dom_objects_json_stats_h);
								}
							}
						}
					}
				}
			}
		}
	}
}

my $exec_duration = time - $exec_start;
my $vcenter_exec_duration_h = {
	time() => {
		"$vcenter_name.vsan" . ".exec.duration", $exec_duration,
	},
};
$graphite->send(path => "vi.", data => $vcenter_exec_duration_h);

$logger->info("[INFO] End processing vCenter $vcenterserver");

# disconnect from the server
# Util::disconnect();
