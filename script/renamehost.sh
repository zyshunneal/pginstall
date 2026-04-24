#!/bin/bash

sn=`dmidecode -t1|grep "Serial Number"|awk '{print $NF}'`
server_info=`curl -m 10 "http://10.189.6.240:28888/v1/installos/?sn=${sn}"`
server_ip=`echo "$server_info"|grep "lanip"|awk -F: '{print $2}'`
server_name=`echo "$server_info"|grep "roleDomain"|awk -F: '{print $2}'` 
sed -i "s/HOSTNAME=.*/HOSTNAME=${server_name}.bjs.p1staff.com/" /etc/sysconfig/network
sed -i "/^${server_ip}/d" /etc/hosts
echo -e "${server_ip}\t${server_name}.bjs.p1staff.com" >> /etc/hosts
hostname ${server_name}.bjs.p1staff.com
sed -i "s/"node_name":".*","datacenter"/"node_name":"$(hostname)","datacenter"/"  /etc/consul/consul.json
echo "OK" > /tmp/exec.status
