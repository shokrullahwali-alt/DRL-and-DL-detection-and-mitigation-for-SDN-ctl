# inside ONOS CLI (karaf@root >)
cfg get
# inside karaf (ssh -p 8101 onos@<ip>)

# keep these false unless you know you need them:
cfg set org.onosproject.fwd.ReactiveForwarding matchIpv4Address true
cfg set org.onosproject.fwd.ReactiveForwarding matchIcmpFields  true
cfg set org.onosproject.fwd.ReactiveForwarding matchTcpUdpPorts true
cfg set org.onosproject.fwd.ReactiveForwarding matchIpv4Dscp    true   # optional

# (optional) helpful toggles depending on your setup
cfg set org.onosproject.fwd.ReactiveForwarding recordMetrics     true
cfg set org.onosproject.fwd.ReactiveForwarding inheritFlowTreatment true




useRegionForBalanceRoles


py [
  net["srv1"].cmd("python3 -m http.server 8080 >/tmp/http.log 2>&1 &"),
  net["srv1"].cmd("python3 -m http.server 8081 >/tmp/http2.log 2>&1 &"),
  net["h2"].cmd("python3 -m http.server 8082 >/tmp/h2_http.log 2>&1 &"),
  net["srv1"].cmd("iperf -s -p 5001 >/tmp/iperf_tcp.log 2>&1 &"),
  net["srv1"].cmd("iperf -s -u -p 5002 >/tmp/iperf_udp.log 2>&1 &"),
  net["h1"].cmd("bash -lc 'while true; do curl -s --max-time 4 http://10.10.0.200:8080/?id=$RANDOM >/dev/null 2>&1; sleep $((10 + RANDOM % 30)); done &'"),
  net["h2"].cmd("bash -lc 'while true; do curl -s --max-time 4 http://10.10.0.200:8081/?req=$RANDOM >/dev/null 2>&1; sleep $((40 + RANDOM % 50)); done &'"),
  net["h3"].cmd("bash -lc 'while true; do wget -q -O /dev/null --timeout=4 http://10.10.0.200:8080/data?q=$RANDOM; sleep $((50 + RANDOM % 40)); done &'"),
  net["h4"].cmd("bash -lc 'while true; do curl -s --max-time 4 http://10.10.0.102:8082/?src=h4 >/dev/null 2>&1; sleep $((60 + RANDOM % 40)); done &'"),
  net["iot1"].cmd("bash -lc 'while true; do timeout 3 curl -s http://10.10.0.200:8080/status >/dev/null 2>&1; sleep $((100 + RANDOM % 70)); done &'"),
  net["iot2"].cmd("bash -lc 'while true; do timeout 3 curl -s http://10.10.0.200:8081/heartbeat >/dev/null 2>&1; sleep $((125 + RANDOM % 90)); done &'"),
  net["h1"].cmd("bash -lc 'while true; do iperf -c 10.10.0.200 -p 5001 -t $((30 + RANDOM % 40)) -b $((5 + RANDOM % 15))M >/dev/null 2>&1; sleep $((60 + RANDOM % 60)); done &'"),
  net["h4"].cmd("bash -lc 'while true; do iperf -c 10.10.0.200 -p 5001 -t $((25 + RANDOM % 35)) -b $((3 + RANDOM % 10))M >/dev/null 2>&1; sleep $((30 + RANDOM % 30)); done &'"),
  net["h3"].cmd("bash -lc 'while true; do iperf -u -c 10.10.0.200 -p 5002 -t $((20 + RANDOM % 30)) -b $((100 + RANDOM % 200))K >/dev/null 2>&1; sleep $((45 + RANDOM % 40)); done &'"),
  net["h3"].cmd("bash -lc 'while true; do iperf -u -c 10.10.0.200 -p 5002 -t $((20 + RANDOM % 30)) -b $((100 + RANDOM % 200))K >/dev/null 2>&1; sleep $((30 + RANDOM % 40)); done &'"),
  net["iot1"].cmd("bash -lc 'while true; do iperf -u -c 10.10.0.200 -p 5002 -t $((15 + RANDOM % 25)) -b $((50 + RANDOM % 100))K >/dev/null 2>&1; sleep $((60 + RANDOM % 50)); done &'"),
  net["h1"].cmd("bash -lc 'while true; do ping -c $((2 + RANDOM % 4)) -i $((10 + RANDOM % 15)) 10.10.0.102 >/tmp/h1_ping.log 2>&1; sleep $((10 + RANDOM % 20)); done &'"),
  net["h4"].cmd("bash -lc 'while true; do ping -c $((2 + RANDOM % 3)) -i $((12 + RANDOM % 18)) 10.10.0.200 >/tmp/h4_ping.log 2>&1; sleep $((10 + RANDOM % 20)); done &'"),
  net["iot2"].cmd("bash -lc 'while true; do ping -c 1 -i $((20 + RANDOM % 30)) 10.10.0.101 >/tmp/iot2_ping.log 2>&1; sleep $((20 + RANDOM % 30)); done &'"),
  net["h2"].cmd("bash -lc 'while true; do dig @10.10.0.200 example.com A +time=2 >/dev/null 2>&1; sleep $((60 + RANDOM % 50)); done &'"),
  net["h3"].cmd("bash -lc 'while true; do dig @10.10.0.200 google.com A +time=2 >/dev/null 2>&1; sleep $((70 + RANDOM % 50)); done &'"),
  net["srv1"].cmd("bash -lc 'echo 0 $(date +%s) INIT > /tmp/label_state'")
]





# --- IGNORE ---


echo "1 h2_NETWORK_DDOS" >> /tmp/label_state
end=$((SECONDS+90))
while [ $SECONDS -lt $end ]; do 
  # ICMP Flood (Random size betwen 64-1024 bytes)
  for i in {1..120}; do ping -c 2 -W 0.3 -s $((RANDOM % 960 + 64)) 10.10.0.200 & done
  
  # SYN Flood (Random Destination Port 1-65535)
  for i in {1..80}; do hping3 -S -p $((RANDOM % 65535 + 1)) -c 3 --fast 10.10.0.200 & done
  
  # UDP Flood (Random Port)
  for i in {1..75}; do echo "UDP_FLOOD" | nc -u -w0 10.10.0.200 $((RANDOM % 65535 + 1)) & done
  
  # Fragmentation Attacks (Random Port)
  for i in {1..50}; do hping3 -f -p $((RANDOM % 65535 + 1)) -c 2 10.10.0.200 & done
    
  sleep 0.2
done
sleep 15 && echo "0 BENIGN" >> /tmp/label_state


echo "1 h2_NETWORK_DDOS 10.10.0.2" >> /tmp/label_state
end=$((SECONDS+100))
while [ $SECONDS -lt $end ]; do 
  for i in {1..120}; do ping -c 2 -W 0.3 -s $((RANDOM % 960 + 64)) 10.10.0.200 & done
  for i in {1..80}; do hping3 -S -p $((RANDOM % 65535 + 1)) -c 3 --fast 10.10.0.200 & done
  for i in {1..75}; do echo "UDP_FLOOD" | nc -u -w0 10.10.0.200 $((RANDOM % 65535 + 1)) & done
  for i in {1..50}; do hping3 -f -p $((RANDOM % 65535 + 1)) -c 2 10.10.0.200 & done
  sleep 0.2
done
sleep 15 && echo "0 BENIGN" >> /tmp/label_state



echo "1 h4_NETWORK_DDOS 10.10.0.4" >> /tmp/label_state
end=$((SECONDS+100))
while [ $SECONDS -lt $end ]; do 
  for i in {1..120}; do ping -c 2 -W 0.3 -s $((RANDOM % 960 + 64)) 10.10.0.200 & done
  for i in {1..80}; do hping3 -S -p $((RANDOM % 65535 + 1)) -c 3 --fast 10.10.0.200 & done
  for i in {1..75}; do echo "UDP_FLOOD" | nc -u -w0 10.10.0.200 $((RANDOM % 65535 + 1)) & done
  for i in {1..50}; do hping3 -f -p $((RANDOM % 65535 + 1)) -c 2 10.10.0.200 & done
  sleep 0.2
done
sleep 15 && echo "0 BENIGN" >> /tmp/label_state


echo "1 iot2_NETWORK_DDOS 10.10.0.102" >> /tmp/label_state
end=$((SECONDS+100))
while [ $SECONDS -lt $end ]; do 
  for i in {1..120}; do ping -c 2 -W 0.3 -s $((RANDOM % 960 + 64)) 10.10.0.200 & done
  for i in {1..80}; do hping3 -S -p $((RANDOM % 65535 + 1)) -c 3 --fast 10.10.0.200 & done
  for i in {1..75}; do echo "UDP_FLOOD" | nc -u -w0 10.10.0.200 $((RANDOM % 65535 + 1)) & done
  for i in {1..50}; do hping3 -f -p $((RANDOM % 65535 + 1)) -c 2 10.10.0.200 & done
  sleep 0.2
done
sleep 15 && echo "0 BENIGN" >> /tmp/label_state


