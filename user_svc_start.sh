#!/bin/bash

# Author: Erik Bryer, erik.bryer@gmail.com
# License: GPLv3

#####################
# user_svc_start.sh #
#####################
# This idempotent script adds users and starts associated user systemd
# services named ${USER}_lm. 

#########################
# How this script works #
#########################
#   1. An entry "username 2000700000" in the USERS array triggers 
#      creation of user username with uid=gid=2000700000 and 
#      subuid and subgid ranges of 2000700001 - 2000799999. 
#   2. Next, "systemctl --user start username_lm" runs a user 
#      systemd unit file stored in username's home directory: 
#      ~/.config/systemd/user/username_lm.service. This file does not 
#      have to exist when you first run this script to create the user; 
#      however, once the user systemd unit file is in place, a subsequent 
#      run of this script will start the service. To clarify, this script 
#      expects the user systemd unit file to be named username_lm.service
#      and for this service to start the container running the licensing
#      daemon. This script is idempotent.

###########
# Caveats #
###########
#   - Uid ranges defined in USERS must be incremented by 100000. 
#     For example, if the last entry in USERS is "userA 2000700000", then 
#     the next entry should be "userB 2000800000". 
#   - This script expects PAM to be in use and so modifies
#     /etc/security/access.conf to allow local logins from root to the 
#     users in USERS.
#   - If a uid in /etc/passwd gets out of sync with the uid on files in
#     that user's home directory, it's recommended to, e.g.: 
#     "mv /home/userB /home/userB.bak ; userdel -r userB"
#     and start over with a new entry: "userB 2000900000".

#
# Usernames/uids may be separated by any combination of tabs, spaces & newlines.
#username    uid
USERS=(
gurobi       2000000000
schrodinger  2000100000
tecplot      2000200000
xfdtd        2000300000
ampl         2000400000
totalview    2000500000
)

HOMEROOT="/home"
SUBUID_INC=99999

# This script was written for a stateless system that has an 
# attached disk that is not automatically mounted at boot.
mount /dev/sda $HOMEROOT
dnf -y --quiet install podman

# generate the ssh key pair if it doesn't already exist
if ! [[ -e /root/.ssh/id_rsa && -e /root/.ssh/id_rsa.pub ]]; then
    ssh-keygen -q -t rsa -N '' -f /root/.ssh/id_rsa <<<y &>/dev/null
fi

# i is a counter variable that starts at 0. Loop through each element in USERS.
for i in ${!USERS[@]}; do
    # run commands for each username/uid pair
    if [[ $(($i%2)) -eq 0 ]]; then
        username=${USERS[i]}
        homedir="/$HOMEROOT/$username"
        # get the next element in the USERS array
        uid=${USERS[$(($i + 1))]}  

        # create group: group_name=user_name, gid=uid
        groupadd --gid $uid $username

        # Create the user but don't try to create a same-named group.
        # If the home dir already exists, it will warn but still add the user
        # to /etc/passwd.
        useradd --create-home --home-dir $homedir --gid $uid \
                --uid $uid --no-user-group $username
        # create subuid and subgid ranges
        usermod --add-subuids $(($uid + 1))-$(($uid + $SUBUID_INC)) $username
        usermod --add-subgids $(($uid + 1))-$(($uid + $SUBUID_INC)) $username
        # debug
        #tail -n 1 /etc/passwd /etc/group /etc/shadow /etc/subuid /etc/subgid
        #tail -n 4 /etc/security/access.conf

        # enable the user's started processes to persist after logout
        loginctl enable-linger $username

        # Tell PAM to allow root to ssh username@localhost by inserting
        # a line before final line of access.conf, if necessary.
        grep $username /etc/security/access.conf &>/dev/null
        if [[ $? -ne 0 ]]; then
            sed -i "s/\-:ALL:ALL/+:$username:127.0.0.1 ::1\n\-:ALL:ALL/" \
            /etc/security/access.conf
            # don't violate systemd's StartLimitInterval
            sleep 3
            systemctl restart sshd
        fi

        # add root's public key to username's authorized_keys if necessary
        grep --fixed-strings --file=/root/.ssh/id_rsa.pub \
        $homedir/.ssh/authorized_keys &>/dev/null
        if [[ $? -ne 0 ]]; then
            mkdir -p $homedir/.ssh
            chmod 700 $homedir/.ssh
            cat /root/.ssh/id_rsa.pub >> $homedir/.ssh/authorized_keys
            chmod 600 $homedir/.ssh/authorized_keys
            chown -R $username:$username $homedir/.ssh
        fi

        # Inform podman of the changes to /etc/sub{u,g}id and start the 
        # service that starts the container. Using ssh to switch user 
        # yields a clean login session environment, whereas su does not.
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        $username@localhost podman system migrate
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        $username@localhost systemctl --user daemon-reload
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        $username@localhost systemctl --user enable ${username}_lm
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        $username@localhost systemctl --user start ${username}_lm
    fi
done

exit 0
