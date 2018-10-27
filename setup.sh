#!/bin/bash

XML_DIR="$PWD/files"
LOG_DIR="$PWD/logs"
TMP_DIR="$PWD/tmp"
CONF_DIR="$PWD/conf"
OUTPUT_DIR="$PWD/output-qemu"
IMAGES_DIR="/home/images"

if [ ! -d $TMP_DIR ]
then
   mkdir -p $TMP_DIR
fi

if [ ! -d $LOG_DIR ]
then
   mkdir -p $LOG_DIR
fi

EXTMASK="255.255.255.0"
EXTIP_STARTS="192.168.100"
EXTGW="192.168.100.1"
EXTDOMAIN="depa.mx"
EXTH=101

INTMASK="255.240.0.0"
INTIP_STARTS="172.16.0"
INTGW="172.16.0.1"
INTDOMAIN="internal.depa.mx"
INTH=2
INTVIRNAME="virbr0"

echo -n > $TMP_DIR/host-mac
echo -n > $TMP_DIR/host-ip

#Check if template img exists, if not, create it
if [ ! -f $XML_DIR/template.img ]
then
   if [ ! -f packer ]
   then
      wget https://releases.hashicorp.com/packer/1.3.1/packer_1.3.1_linux_amd64.zip
      unzip packer_1.3.1_linux_amd64.zip
   fi
   if [ -d $OUTPUT_DIR ]
   then
      rm -rf $OUTPUT_DIR
   fi
   PACKER_LOG=1 PACKER_LOG_PATH=$LOG_DIR/packer.log $PWD/packer build $PWD/centos7-template.json &
   echo -e "Be patient :D, It can take long time\nDo not stop!!!"
   wait
   if [ -f $OUTPUT_DIR/template.img ]
   then
      mv $OUTPUT_DIR/template.img $XML_DIR/template.img
      ln -s $XML_DIR/template.img $PWD/template.img
   else
      echo "Template img was not generated, please review $LOG_DIR/packer.log"
      exit 1
   fi
fi

for row in $(cat $1)
do
   SUFFIX=$(echo $row | cut -d ',' -f1)
   NUM=$(echo $row | cut -d ',' -f2)
   PUBLIC=$(echo $row | cut -d ',' -f3)
   for i in $(seq -f "%02g" 1 $NUM)
   do
      OLD_NAME=$(awk -F '[><]' '/<name>/{print $3}' $XML_DIR/$2.xml)
      NEW_NAME=$SUFFIX$i
      echo "Working on $NEW_NAME"
      OLD_MAC=$(awk -F \' '/mac address/{print $2}' $XML_DIR/$2.xml)
      NEW_MAC=$(echo "52:54:00:$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | md5sum | sed 's/^\(..\)\(..\)\(..\).*$/\1:\2:\3/')")
      MAC_UPPER=$(echo $NEW_MAC | tr '[:lower:]' '[:upper:]')
      cp $XML_DIR/$2.xml $XML_DIR/$NEW_NAME.xml
      sed 's/$OLD_NAME/$NEW_NAME/g;s/$OLD_MAC/$NEW_MAC/g' -i $XML_DIR/$NEW_NAME.xml
      if [ ! -z $PUBLIC ]
      then
         OLD_MAC1=$(awk -F \' '/mac address/{print $2}' $XML_DIR/nic.xml)
         NEW_MAC1=$(echo "52:54:00:$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | md5sum | sed 's/^\(..\)\(..\)\(..\).*$/\1:\2:\3/')")
         sed "s/$OLD_MAC1/$NEW_MAC1/g" -i $XML_DIR/nic.xml
         sed '/<\/interface>/r files/nic.xml' -i $XML_DIR/$NEW_NAME.xml
         sed "s/NETMASK.*/NETMASK=$EXTMASK/;s/IPADDR.*/IPADDR=$EXTIP_STARTS.$EXTH/;s/GATEWAY.*/GATEWAY=$EXTGW/" -i $CONF_DIR/ifcfg-eth1
         echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver $EXTGW" > $CONF_DIR/resolv.conf
         let EXTH+=1
      fi
      if [ ! -d $IMAGES_DIR ]
      then
         mkdir -p $IMAGES_DIR
      fi
      #String:2 to remove the first 2 characters 
      virt-clone --name $NEW_NAME --file $IMAGES_DIR/dsk${NEW_NAME:2}.img --original-xml $XML_DIR/$NEW_NAME.xml --mac $MAC_UPPER &>> $LOG_DIR/clone.log
      virt-sysprep -d $NEW_NAME  --hostname $NEW_NAME.$EXTDOMAIN &>> $LOG_DIR/clone.log
      echo "$NEW_NAME,$MAC_UPPER" >> $TMP_DIR/host-mac
      virt-copy-in -d $NEW_NAME $CONF_DIR/ifcfg-eth0 /etc/sysconfig/network-scripts/
      virt-copy-in -d $NEW_NAME $CONF_DIR/resolv.conf /etc/
      if [ ! -z $PUBLIC ]
      then
         virt-copy-in -d $NEW_NAME $CONF_DIR/ifcfg-eth1 /etc/sysconfig/network-scripts/
      fi
   done
done

#Renew template file
sed "/<name>/s/>.*.</>$INTVIRNAME</;s/ip address='[^']*'/ip address='$INTGW'/;s/netmask='[^']*'/netmask='$INTMASK'/;/bridge name/s/name='[^']*'/name='$INTVIRNAME'/;/range start/s/start='[^']*'/start='$INTIP_STARTS.$INTH'/;/range start/s/end='[^']*'/end='$INTIP_STARTS.254'/" -i $XML_DIR/$INTVIRNAME.xml
#Remove all entries
sed "/host mac/d" -i $XML_DIR/$INTVIRNAME.xml

#Bind MAC to an IP address
for row in $(cat $TMP_DIR/host-mac)
do
   HOST_NAME=$(echo $row | cut -d "," -f1)
   INTMAC=$(echo $row | cut -d "," -f2 | tr '[A-Z]' '[a-z]')
   #Add new entry
   sed "/range start/a \      <host mac='$INTMAC' name='$HOST_NAME' ip='$INTIP_STARTS.$INTH'/>" -i $XML_DIR/$INTVIRNAME.xml
   echo "$HOST_NAME,$INTIP_STARTS.$INTH" >> $TMP_DIR/host-ip
   let   INTH=INTH+1
done

#Create virbr based on the xml file created before
virsh net-destroy $INTVIRNAME
virsh net-undefine $INTVIRNAME
virsh net-define $XML_DIR/$INTVIRNAME.xml
virsh net-start $INTVIRNAME
virsh net-autostart $INTVIRNAME

#Create hosts file for KVM and starts the VMs
for vm in $(cat $TMP_DIR/host-ip)
do
   VM_NAME=$(echo $vm | cut -d ',' -f1)
   VM_IP=$(echo $vm | cut -d ',' -f2)
   virsh start $VM_NAME
   sed "/$VM_NAME/d;/$VM_IP/d" -i /etc/hosts
   echo "$VM_IP   $VM_NAME   $VM_NAME.$INTDOMAIN" >> /etc/hosts
   sleep 20
done

#Health check
fping $(awk '/vm/{print $3}' /etc/hosts)
