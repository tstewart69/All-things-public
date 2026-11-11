#!/bin/zsh

if grep -q 'auth.*sufficient.*pam_tid.so' "/etc/pam.d/sudo"; then
  echo 1>&2 "line exists, nothing left to do"
  exit 0
else    
  echo 1>&2 'adding change to /etc/pam.d/sudo'     
  awk 'NR==3{print "auth sufficient pam_tid.so"}1' /etc/pam.d/sudo > /tmp/pam.d_sudo && cp /tmp/pam.d_sudo /etc/pam.d/sudo
  chmod 444 /etc/pam.d/sudo
  echo 1>&2 'change made to /etc/pam.d/sudo'
fi

sudo /usr/local/bin/kandji display-alert --title "Add Touch ID to Sudo" --message "Adding touch ID to Sudo was succesful."
