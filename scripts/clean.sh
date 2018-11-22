#Update packages and upgrade
yum -y update
yum -y upgrade

#Remove avahi and networkmanager
yum -C -y remove avahi\* Network\*

#Disable selinux
rm /etc/sysconfig/selinux
ln -s /etc/selinux/config /etc/sysconfig/selinux
sed -i "s/^\(SELINUX=\).*/\1disabled/g" /etc/selinux/config

#Disable reverse dns lookups on sshd
sed -E 's/#?UseDNS yes/UseDNS no/' -i /etc/ssh/sshd_config

#Disable remotely root login
sed -E 's/#?PermitRootLogin yes/PermitRootLogin no/' -i /etc/ssh/sshd_config

#Remove any ssh keys or persistent routes, dhcp leases
rm -f /etc/ssh/ssh_host_*
rm -f /etc/udev/rules.d/70-persistent-net.rules
rm -f /var/lib/dhclient/*eth0.lease
rm -rf /tmp/*

#Clean up /etc/resolv.conf
rm /etc/resolv.conf
touch /etc/resolv.conf
chown root:root /etc/resolv.conf
chmod 644 /etc/resolv.conf

#Clean up installation logs"
rm -rf /var/log/yum.log
rm -rf /var/lib/yum/*
rm -rf /root/install.log
rm -rf /root/install.log.syslog
rm -rf /root/anaconda-ks.cfg
rm -rf /var/log/anaconda*
rm -rf /root/anac*
yum -y clean all

#Free up space taken by orphaned data from disabled or removed repos
rm -rf /var/cache/yum

#Fix SELinux contexts
touch /var/log/cron
touch /var/log/boot.log
mkdir -p /var/cache/yum
/usr/sbin/fixfiles -R -a restore
