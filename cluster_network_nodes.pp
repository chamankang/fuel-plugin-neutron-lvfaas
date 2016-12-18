notice('MODULAR: cluster_network_nodes.pp')

$host = 'r1-net-1.domain.tld'
$primary = (hiera('fqdn') == $host) ? { true => true, default => false }
$network_scheme   = hiera_hash('network_scheme', {})
prepare_network_config(hiera_hash('network_scheme', {}))

$corosync_input_port          = 5404
$corosync_output_port         = 5405
$pcsd_port                    = 2224
$corosync_networks = get_routable_networks_for_network_role($network_scheme, 'mgmt/corosync')

$corosync_nodes = corosync_nodes(
    get_nodes_hash_by_roles(
        hiera_hash('network_metadata'),
        ['network']
    ),
    'mgmt/corosync'
)
$cluster_recheck_interval = hiera('cluster_recheck_interval', '190s')

openstack::firewall::multi_net {'113 corosync-input':
  port        => $corosync_input_port,
  proto       => 'udp',
  action      => 'accept',
  source_nets => $corosync_networks,
}

openstack::firewall::multi_net {'114 corosync-output':
  port        => $corosync_output_port,
  proto       => 'udp',
  action      => 'accept',
  source_nets => $corosync_networks,
}

openstack::firewall::multi_net {'115 pcsd-server':
  port        => $pcsd_port,
  proto       => 'tcp',
  action      => 'accept',
  source_nets => $corosync_networks,
}

class { 'cluster':
  internal_address         => get_network_role_property('mgmt/corosync', 'ipaddr'),
  corosync_nodes           => $corosync_nodes,
  cluster_recheck_interval => $cluster_recheck_interval,
}

pcmk_nodes { 'pacemaker' :
  nodes => $corosync_nodes,
  add_pacemaker_nodes => false,
}

Service <| title == 'corosync' |> {
  subscribe => File['/etc/corosync/service.d'],
  require   => File['/etc/corosync/corosync.conf'],
}

Service['corosync'] -> Pcmk_nodes<||>
Pcmk_nodes<||> -> Service<| provider == 'pacemaker' |>

# Sometimes during first start pacemaker can not connect to corosync
# via IPC due to pacemaker and corosync processes are run under different users
if($::operatingsystem == 'Ubuntu') {
  $pacemaker_run_uid = 'hacluster'
  $pacemaker_run_gid = 'haclient'

  file {'/etc/corosync/uidgid.d/pacemaker':
    content =>"uidgid {
   uid: ${pacemaker_run_uid}
   gid: ${pacemaker_run_gid}
}"
  }

  File['/etc/corosync/corosync.conf'] -> File['/etc/corosync/uidgid.d/pacemaker'] -> Service <| title == 'corosync' |>
}

file {'/usr/lib/ocf/resource.d/fuel/ocf-neutron-vpn-agent':
  source => 'file:///root/post-working/ocf-neutron-vpn-agent',
  mode => '0755'
}
File['/usr/lib/ocf/resource.d/fuel/ocf-neutron-vpn-agent'] -> Service <| provider == 'pacemaker' |>
File['/usr/lib/ocf/resource.d/fuel/ocf-neutron-vpn-agent'] ~> Service['p_neutron-vpn-agent']

file {'/usr/lib/ocf/resource.d/fuel/ocf-neutron-lbaas-agent':
  source => 'file:///root/post-working/ocf-neutron-lbaas-agent',
  mode => '0755'
}
File['/usr/lib/ocf/resource.d/fuel/ocf-neutron-lbaas-agent'] -> Service <| provider == 'pacemaker' |>
File['/usr/lib/ocf/resource.d/fuel/ocf-neutron-lbaas-agent'] ~> Service['p_neutron-lbaas-agent']

if $primary {
  cs_resource { "p_neutron-ovs-agent":
    ensure          => present,
    primitive_class => 'ocf',
    provided_by     => 'fuel',
    primitive_type  => 'ocf-neutron-ovs-agent',
    metadata        => {
      resource-stickiness => '1'
    },
    parameters      => {
      'plugin_config'                  => '/etc/neutron/plugins/ml2/ml2_conf.ini',
    },
    operations      => {
      'monitor' => {
        'interval' => '20',
        'timeout'  => '30'
      },
      'start'   => {
        'timeout' => '80'
      },
      'stop'    => {
        'timeout' => '80'
      }
    }
  }
  
  cs_resource { "p_neutron-metadata-agent":
    ensure          => present,
    primitive_class => 'ocf',
    provided_by     => 'fuel',
    primitive_type  => 'ocf-neutron-metadata-agent',
    metadata        => {
      resource-stickiness => '1'
    },
    operations      => {
      'monitor' => {
        'interval' => '60',
        'timeout'  => '30'
      },
      'start'   => {
        'timeout' => '30'
      },
      'stop'    => {
        'timeout' => '30'
      }
    }
  }
  
  cs_resource { "p_neutron-vpn-agent":
    ensure          => present,
    primitive_class => 'ocf',
    provided_by     => 'fuel',
    primitive_type  => 'ocf-neutron-vpn-agent',
    metadata        => {
      resource-stickiness => '1'
    },
    parameters      => {
      'plugin_config'                  => '/etc/neutron/vpn_agent.ini',
      'remove_artifacts_on_stop_start' => true,
    },
    operations      => {
      'monitor' => {
        'interval' => '20',
        'timeout'  => '30'
      },
      'start'   => {
        'timeout' => '60'
      },
      'stop'    => {
        'timeout' => '60'
      }
    }
  }
  
  cs_resource { "p_neutron-lbaas-agent":
    ensure          => present,
    primitive_class => 'ocf',
    provided_by     => 'fuel',
    primitive_type  => 'ocf-neutron-lbaas-agent',
    metadata        => {
      resource-stickiness => '1'
    },
    parameters      => {
      'plugin_config'                  => '/etc/neutron/lbaas_agent.ini',
      'remove_artifacts_on_stop_start' => true,
    },
    operations      => {
      'monitor' => {
        'interval' => '20',
        'timeout'  => '30'
      },
      'start'   => {
        'timeout' => '60'
      },
      'stop'    => {
        'timeout' => '60'
      }
    }
  }
  
  ['neutron-ovs-agent', 'neutron-metadata-agent', 'neutron-lbaas-agent'].each |$service| {
    cs_rsc_colocation { "${service}-with-neutron-vpn-agent":
      ensure     => present,
      score      => 'INFINITY',
      primitives => [
        "p_${service}",
        "p_neutron-vpn-agent"
      ],
    }
  }

  Cs_resource<||> -> Service<| ensure == 'stopped' |> -> Service<| provider == 'pacemaker' |> -> Cs_rsc_colocation<||> 
}

ini_setting { "add_neutron_l3_host":
  ensure  => present,
  path    => '/etc/neutron/neutron.conf',
  section => 'DEFAULT',
  setting => 'host',
  value   => $host,
}
Ini_setting['add_neutron_l3_host'] ~> Service<| provider == 'pacemaker' |>

$services = ['neutron-plugin-openvswitch-agent', 'neutron-metadata-agent', 'neutron-lbaas-agent', 'neutron-vpn-agent']
$services.each |String $service| {
  service { $service:
    enable     => false,
    ensure     => stopped,
  }
}

$resources = ['neutron-vpn-agent', 'neutron-ovs-agent', 'neutron-metadata-agent', 'neutron-lbaas-agent']
$resources.each |String $service| {
  service { "p_${service}":
    enable     => true,
    ensure     => running,
    hasstatus  => true,
    hasrestart => false,
    provider   => 'pacemaker',
  }
}

