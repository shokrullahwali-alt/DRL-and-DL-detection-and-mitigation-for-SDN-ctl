#!/usr/bin/env python3
"""

Multi-controller (ONOS cluster) + multi-domain *physical* topology but single logical SDN fabric.
Each host gets:
 - a domain IP (10.0.0.x, 10.0.2.x, 10.0.3.x) — to keep "IoT/SDN/Server" identity
 - a shared fabric IP (10.10.0.x)  — all hosts share this subnet so ONOS must program reactive flows

All switches connect to all controllers (distributed ONOS cluster).
"""
from mininet.net import Mininet
from mininet.node import RemoteController, OVSKernelSwitch
from mininet.link import TCLink
from mininet.cli import CLI

# --- EDIT THESE: your ONOS controller IPs ---
CONTROLLERS = [
    ("c1", "175.24.1.5"),
    ("c2", "175.24.1.6"),
    ("c3", "175.24.1.7"),
]
CPORT = 6653

def addDualStackHost(net, name, domain_ip, fabric_ip):
    """Add host placeholder, we'll assign IPs after build."""
    # set initial ip as fabric_ip to allow Mininet to configure interface
    h = net.addHost(name, ip=fabric_ip)
    h.domain_ip = domain_ip
    h.fabric_ip = fabric_ip
    return h

def run():
    net = Mininet(controller=RemoteController,
                  switch=OVSKernelSwitch,
                  link=TCLink,
                  autoSetMacs=True,
                  build=False)

    # controllers
    ctrls = []
    for cname, cip in CONTROLLERS:
        ctrls.append(net.addController(cname, controller=RemoteController, ip=cip, port=CPORT))

    # switches (core + 3 domain access switches)
    s_core = net.addSwitch('s1', protocols='OpenFlow13', failMode='secure')  # core
    s_sdn  = net.addSwitch('s2', protocols='OpenFlow13', failMode='secure')  # user/enterprise
    s_iot  = net.addSwitch('s3', protocols='OpenFlow13', failMode='secure')  # IoT
    s_srv  = net.addSwitch('s4', protocols='OpenFlow13', failMode='secure')  # server/DC


    # fabric wiring
    net.addLink(s_core, s_sdn)
    net.addLink(s_core, s_iot)
    net.addLink(s_core, s_srv)

    # hosts: SDN/user domain (10.0.0.0/24) -> fabric IPs 10.10.0.1..4
    h1 = addDualStackHost(net, 'h1', '10.0.0.1/24', '10.10.0.1/24')
    h2 = addDualStackHost(net, 'h2', '10.0.0.2/24', '10.10.0.2/24')
    h3 = addDualStackHost(net, 'h3', '10.0.0.3/24', '10.10.0.3/24')
    h4 = addDualStackHost(net, 'h4', '10.0.0.4/24', '10.10.0.4/24')

    # IoT domain (10.0.2.0/24) -> fabric IPs 10.10.0.101..102
    iot1 = addDualStackHost(net, 'iot1', '10.0.2.1/24', '10.10.0.101/24')
    iot2 = addDualStackHost(net, 'iot2', '10.0.2.2/24', '10.10.0.102/24')

    # Server domain (10.0.3.0/24) -> fabric IP 10.10.0.200
    srv1 = addDualStackHost(net, 'srv1', '10.0.3.1/24', '10.10.0.200/24')

    # attach hosts to their domain access switch
    for h in (h1, h2, h3, h4):
        net.addLink(h, s_sdn)
    for h in (iot1, iot2):
        net.addLink(h, s_iot)
    net.addLink(srv1, s_srv)

    # build & start controllers
    net.build()
    for c in ctrls:
        c.start()

    # start switches and point them at all controllers
    ctrl_list = " ".join([f"tcp:{cip}:{CPORT}" for _, cip in CONTROLLERS])
    for sw in (s_core, s_sdn, s_iot, s_srv):
        sw.start(ctrls)
        sw.cmd(f'ovs-vsctl set Bridge {sw.name} protocols=OpenFlow13')
        sw.cmd(f'ovs-vsctl set-fail-mode {sw.name} secure')
        sw.cmd(f'ovs-vsctl set-controller {sw.name} {ctrl_list}')

    # assign both addresses to each host interface
    for h in (h1, h2, h3, h4, iot1, iot2, srv1):
        intf = h.defaultIntf()
        # remove any auto-assigned ip, then add both addresses
        h.cmd(f'ip addr flush dev {intf}')
        h.cmd(f'ip addr add {h.fabric_ip} dev {intf}')
        h.cmd(f'ip addr add {h.domain_ip} dev {intf}')
        h.cmd(f'ip link set {intf} up')

    print("\n✅ Multi-controller, multi-domain (physical) SDN fabric is up.")
    print("Domains & host IPs:")
    print("  SDN/users (s_sdn):  h1..h4 -> domain IPs 10.0.0.x, fabric IPs 10.10.0.1..4")
    print("  IoT (s_iot):        iot1,iot2 -> domain IPs 10.0.2.x, fabric 10.10.0.101/102")
    print("  Server (s_srv):     srv1 -> domain IP 10.0.3.1, fabric 10.10.0.200")
    print("\nEXERCISES (Mininet CLI):")
    print("  pingall")
    print("  h1 ping -c3 10.10.0.200     # h1 -> srv1 using fabric IPs (ONOS should program flows)")
    print("  iot1 ping -c3 10.10.0.4     # cross-domain on fabric subnet")
    print("  h1 iperf -c 10.10.0.200 -p 8080 -t 5")
    print("\nVerify in ONOS (ssh to any controller, e.g. -p 8101):")
    print("  apps -s       # ensure org.onosproject.fwd is active")
    print("  hosts         # ONOS should list hosts with 10.10.0.x attachment")
    print("  flows         # look for appId=org.onosproject.fwd and IPV4_SRC/IPV4_DST/TCP_* criteria\n")

    CLI(net)
    net.stop()

if __name__ == '__main__':
    run()
