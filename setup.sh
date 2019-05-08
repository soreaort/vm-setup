#!/bin/bash

XML_DIR="$PWD/files"
LOG_DIR="$PWD/logs"
TMP_DIR="$PWD/tmp"
CONF_DIR="$PWD/conf"
OUTPUT_DIR="$PWD/output-qemu"
IMAGES_DIR="/home/images"
SERVER_LIST="input-vm"
TEMPLATE="template"
SYSTEM=$(uname | tr '[:upper:]' '[:lower:]')
PACKER_VERSION="1.3.1"

PUBMASK="255.255.255.0"
PUBIP_STARTS="192.168.100"
PUBGW="192.168.100.1"
PUBDOMAIN="depa.mx"
PUBH=101

MGTMASK="255.0.0.0"
MGTIP_STARTS="10.0.0"
MGTGW="10.0.0.1"
MGTDOMAIN="mgt.depa.mx"
MGTH=101

STGMASK="255.240.0.0"
STGIP_STARTS="172.16.0"
STGGW="172.16.0.1"
STGDOMAIN="stg.depa.mx"
STGH=2
STGVIRNAME="virbr0"

if [ $(id -u) != 0 ]
then
   echo -e "$0 should be executed as root!!!\nExiting..."
   exit 1
fi

if [ ! -d $TMP_DIR ]
then
   mkdir -p $TMP_DIR
fi

if [ ! -d $LOG_DIR ]
then
   mkdir -p $LOG_DIR
fi

echo -n > $TMP_DIR/host-mac
echo -n > $TMP_DIR/host-ip

echo "Validating if template.img exits"
if [ ! -f $OUTPUT_DIR/template.img ]
then
   echo "template.img does not exit, checking if packer tool is installed"
   if [ ! -f packer ]
   then
      echo "It is not installed, downloading and installing packer $PACKER_VERSION ..."
      wget https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_${SYSTEM}_amd64.zip -O packer.zip
      unzip packer.zip
   fi
   if [ -d $OUTPUT_DIR ]
   then
      echo "Removing output dir to avoid issues"
      rm -rf $OUTPUT_DIR
   fi
   PACKER_LOG=1 PACKER_LOG_PATH=$LOG_DIR/packer.log $PWD/packer build $PWD/centos7-template.json &
   echo -e "Building template image, Please be patient :D, It can take up to 30 minutes\nDo not stop!!!"
   wait
   if [ -f $OUTPUT_DIR/template.img ]
   then
      echo "Creating symlinks needed"
      ln -s $OUTPUT_DIR/template.img $XML_DIR/template.img
      ln -s $OUTPUT_DIR/template.img $PWD/template.img
   else
      echo "There was and issue and template img was not generated, please review $LOG_DIR/packer.log"
      exit 1
   fi
else
   echo "Checking if symlinks are in place"
   if [ ! -f $XML_DIR/template.img ]
   then
      echo "Creating symlink in $XML_DIR"
      ln -s $OUTPUT_DIR/template.img $XML_DIR/template.img
   fi
   if [ ! -f $PWD/template.img ]
   then
      echo "Creating symlink in $PWD"
      ln -s $OUTPUT_DIR/template.img $PWD/template.img
   fi
fi

echo "Creating VMs listed on $SERVER_LIST"
for row in $(cat $SERVER_LIST)
do
   SUFFIX=$(echo $row | cut -d ',' -f1)
   NUM=$(echo $row | cut -d ',' -f2)
   PUBLIC=$(echo $row | cut -d ',' -f3)
   for i in $(seq -f "%02g" 1 $NUM)
   do
      OLD_NAME=$(awk -F '[><]' '/<name>/{print $3}' $XML_DIR/$TEMPLATE.xml)
      NEW_NAME=$SUFFIX$i
      echo "Working on $NEW_NAME"
      OLD_MAC=$(awk -F \' '/mac address/{print $2}' $XML_DIR/$TEMPLATE.xml)
      NEW_MAC=$(echo "52:54:00:$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | md5sum | sed 's/^\(..\)\(..\)\(..\).*$/\1:\2:\3/')")
      MAC_UPPER=$(echo $NEW_MAC | tr '[:lower:]' '[:upper:]')
      cp $XML_DIR/$TEMPLATE.xml $XML_DIR/$NEW_NAME.xml
      sed 's/$OLD_NAME/$NEW_NAME/g;s/$OLD_MAC/$NEW_MAC/g' -i $XML_DIR/$NEW_NAME.xml
      OLD_MAC1=$(awk -F \' '/mac address/{print $2}' $XML_DIR/nic-virbr1.xml)
      NEW_MAC1=$(echo "52:54:00:$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | md5sum | sed 's/^\(..\)\(..\)\(..\).*$/\1:\2:\3/')")
      sed "s/$OLD_MAC1/$NEW_MAC1/g" -i $XML_DIR/nic-virbr1.xml
      sed '/<\/interface>/r files/nic-virbr1.xml' -i $XML_DIR/$NEW_NAME.xml
      sed "s/NETMASK.*/NETMASK=$MGTMASK/;s/IPADDR.*/IPADDR=$MGTIP_STARTS.$MGTH/;s/GATEWAY.*/GATEWAY=$MGTGW/" -i $CONF_DIR/ifcfg-eth1
      echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver $MGTGW" > $CONF_DIR/resolv.conf
      let MGTH+=1
      if [ ! -z $PUBLIC ]
      then
         OLD_MAC2=$(awk -F \' '/mac address/{print $2}' $XML_DIR/nic-virbr2.xml)
         NEW_MAC2=$(echo "52:54:00:$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | md5sum | sed 's/^\(..\)\(..\)\(..\).*$/\1:\2:\3/')")
         sed "s/$OLD_MAC2/$NEW_MAC2/g" -i $XML_DIR/nic-virbr2.xml
         sed '/<\/serial>/r files/nic-virbr2.xml' -i $XML_DIR/$NEW_NAME.xml
         sed "s/NETMASK.*/NETMASK=$PUBMASK/;s/IPADDR.*/IPADDR=$PUBIP_STARTS.$PUBH/;s/GATEWAY.*/GATEWAY=$PUBGW/" -i $CONF_DIR/ifcfg-eth2
         let PUBH+=1
      fi
      if [ ! -d $IMAGES_DIR ]
      then
         mkdir -p $IMAGES_DIR
      fi
      #String:2 to remove the first 2 characters 
      virt-clone --name $NEW_NAME --file $IMAGES_DIR/dsk${NEW_NAME:2}.img --original-xml $XML_DIR/$NEW_NAME.xml --mac $MAC_UPPER &>> $LOG_DIR/clone.log
      virt-sysprep -d $NEW_NAME  --hostname $NEW_NAME.$MGTDOMAIN &>> $LOG_DIR/clone.log
      echo "$NEW_NAME,$MAC_UPPER" >> $TMP_DIR/host-mac
      virt-copy-in -d $NEW_NAME $CONF_DIR/ifcfg-eth0 /etc/sysconfig/network-scripts/
      virt-copy-in -d $NEW_NAME $CONF_DIR/ifcfg-eth1 /etc/sysconfig/network-scripts/
      virt-copy-in -d $NEW_NAME $CONF_DIR/resolv.conf /etc/
      if [ ! -z $PUBLIC ]
      then
         virt-copy-in -d $NEW_NAME $CONF_DIR/ifcfg-eth2 /etc/sysconfig/network-scripts/
      fi
   done
done

#Renew template file
sed "/<name>/s/>.*.</>$STGVIRNAME</;s/ip address='[^']*'/ip address='$STGGW'/;s/netmask='[^']*'/netmask='$STGMASK'/;/bridge name/s/name='[^']*'/name='$STGVIRNAME'/;/range start/s/start='[^']*'/start='$STGIP_STARTS.$STGH'/;/range start/s/end='[^']*'/end='$STGIP_STARTS.254'/" -i $XML_DIR/$STGVIRNAME.xml
#Remove all entries
sed "/host mac/d" -i $XML_DIR/$STGVIRNAME.xml

#Bind MAC to an IP address
for row in $(cat $TMP_DIR/host-mac)
do
   HOST_NAME=$(echo $row | cut -d "," -f1)
   STGMAC=$(echo $row | cut -d "," -f2 | tr '[A-Z]' '[a-z]')
   #Add new entry
   sed "/range start/a \      <host mac='$STGMAC' name='$HOST_NAME' ip='$STGIP_STARTS.$STGH'/>" -i $XML_DIR/$STGVIRNAME.xml
   echo "$HOST_NAME,$STGIP_STARTS.$STGH" >> $TMP_DIR/host-ip
   let   STGH=STGH+1
done

#Create virbr based on the xml file created before
echo "Create virttual net..."
virsh net-destroy $STGVIRNAME
virsh net-undefine $STGVIRNAME
virsh net-define $XML_DIR/$STGVIRNAME.xml
virsh net-start $STGVIRNAME
virsh net-autostart $STGVIRNAME

#Create hosts file for KVM and starts the VMs
echo "Starting VMs and filling up hosts file in the kvm server"
for vm in $(cat $TMP_DIR/host-ip)
do
   VM_NAME=$(echo $vm | cut -d ',' -f1)
   VM_IP=$(echo $vm | cut -d ',' -f2)
   virsh start $VM_NAME
   sed "/$VM_NAME/d;/$VM_IP/d" -i /etc/hosts
   echo "$VM_IP   $VM_NAME   $VM_NAME.$STGDOMAIN" >> /etc/hosts
   sleep 20
done

#Health check
echo "Pinging created VMs..."
fping $(awk '/vm/{print $3}' /etc/hosts)
