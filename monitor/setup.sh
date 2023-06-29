#!/bin/bash

set -e

if [ "$RUNNER_OS" = "macOS" ]; then

  sudo sysadminctl -addUser mitmproxyuser -admin
  # echo "mitmproxyuser ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers

  # install requests for mitm plugin
  pip3 install mitmproxy requests
  sudo cp mitm_plugin.py /Users/mitmproxyuser/mitm_plugin.py

  # start mitmdump in simple mode for now to generate CA certificate
  sudo -u mitmproxyuser -H bash -e -c "cd /Users/mitmproxyuser && mitmdump &"

  # wait for mitmdump to start and generate CA certificate
  counter=0
  while [ ! -f /Users/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem ]
  do
    echo "waiting for mitmdump to generate the certificate..."
    sleep 1
    counter=$((counter+1))
    if [ $counter -gt 10 ]; then
      exit 1
    fi
  done

  # kill mitmdump, we'll start it again in transparent mode
  pid=$(sudo lsof -i -P -n 2>/dev/null | sed -En "s/Python *([0-9]*) *mitmproxyuser *.*TCP \*:8080 \(LISTEN\)/\1/p" | head -1)
  sudo kill $pid

  # install mitmproxy certificate as CA
  # disable any GUI prompts for certificate installation
  sudo security authorizationdb write com.apple.trust-settings.admin allow
  # the command itself may run https requests, this is why we didn't setup transparent proxy yet
  # TODO: check if -r trustRoot is needed
  sudo security add-trusted-cert -d -p ssl -p basic -k /Library/Keychains/System.keychain /Users/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem
  # sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /Users/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem
  # curl doesn't use the system keychain, so we need to add the certificate to the openssl keychain
  # TODO: get openssl dir with openssl version -a
  sudo cat /Users/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem >> /usr/local/etc/openssl@1.1/cert.pem
  # set environment variable for NodeJS to use the certificate
  echo "NODE_EXTRA_CA_CERTS=/Users/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem" >> $GITHUB_ENV
  # set environment variable for the Python requests library to use the certificate
  echo "REQUESTS_CA_BUNDLE=/Users/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem" >> $GITHUB_ENV
  # set environment variable for the Elixir Hex package manager to use the certificate
  echo "HEX_CACERTS_PATH=/Users/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem" >> $GITHUB_ENV

  # Enable IP forwarding.
  sudo sysctl -w net.inet.ip.forwarding=1
  # Configure pf with the rules and enable it
  sudo pfctl -f pf.conf
  sudo pfctl -e
  # Configure sudoers to allow mitmproxy to access pfctl.
  echo "ALL ALL=NOPASSWD: /sbin/pfctl -s state" | sudo tee -a /etc/sudoers

  # finally, start mitmdump in transparent mode
  sudo -u mitmproxyuser -H bash -e -c "cd /Users/mitmproxyuser && mitmdump --mode transparent --showhost -q -s /Users/mitmproxyuser/mitm_plugin.py --set output='/Users/mitmproxyuser/out.txt' --set token='$INPUT_TOKEN' --set hosts='api.github.com,github.com' --set debug='$RUNNER_DEBUG' --set ACTIONS_ID_TOKEN_REQUEST_URL='$ACTIONS_ID_TOKEN_REQUEST_URL' --set ACTIONS_ID_TOKEN_REQUEST_TOKEN='$ACTIONS_ID_TOKEN_REQUEST_TOKEN' --set GITHUB_REPOSITORY_ID='$GITHUB_REPOSITORY_ID' --set GITHUB_REPOSITORY='$GITHUB_REPOSITORY' &"

  # wait for mitmdump to start
  counter=0
  while [ ! $(sudo lsof -i -P -n 2>/dev/null | sed -En "s/Python *([0-9]*) *mitmproxyuser *.*TCP \*:8080 \(LISTEN\)/\1/p" | head -1) ]
  do
    echo "waiting for mitmdump to start..."
    sleep 1
    counter=$((counter+1))
    if [ $counter -gt 10 ]; then
      exit 1
    fi
  done

  echo "pid is $(sudo lsof -i -P -n 2>/dev/null | sed -En "s/Python *([0-9]*) *mitmproxyuser *.*/\1/p" | head -1)"

elif [ "$RUNNER_OS" = "Linux" ]; then

  sudo apt update
  sudo apt install -y python3-pip software-properties-common

  # install python 3.9, otherwise ubuntu installs 3.8 and we won't get the latest mitmproxy with important bug fixes
  sudo add-apt-repository ppa:deadsnakes/ppa -y
  sudo apt install -y python3.9 python3.9-distutils

  # create mitmproxyuser, otherwise proxy won't intercept local trafic from the same user
  sudo useradd --create-home mitmproxyuser
  sudo passwd -d mitmproxyuser

  # install mitmproxy
  sudo cp get-pip.py /home/mitmproxyuser/get-pip.py
  sudo -u mitmproxyuser -H bash -e -c 'cd ~ && python3.9 get-pip.py && ~/.local/bin/pip3.9 install --user mitmproxy'

  sudo cp mitm_plugin.py /home/mitmproxyuser/mitm_plugin.py
  sudo -u mitmproxyuser -H bash -e -c "cd /home/mitmproxyuser && /home/mitmproxyuser/.local/bin/mitmdump --mode transparent --showhost --set block_global=false -q -s /home/mitmproxyuser/mitm_plugin.py --set output='/home/mitmproxyuser/out.txt' --set token='$INPUT_TOKEN' --set hosts='api.github.com,github.com' --set debug='$RUNNER_DEBUG' --set ACTIONS_ID_TOKEN_REQUEST_URL='$ACTIONS_ID_TOKEN_REQUEST_URL' --set ACTIONS_ID_TOKEN_REQUEST_TOKEN='$ACTIONS_ID_TOKEN_REQUEST_TOKEN' --set GITHUB_REPOSITORY_ID='$GITHUB_REPOSITORY_ID' --set GITHUB_REPOSITORY='$GITHUB_REPOSITORY' &"

  # wait for mitmdump to start and generate CA certificate
  counter=0
  while [ ! -f /home/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem ]
  do
    echo "waiting for mitmdump to generate the certificate..."
    sleep 1
    counter=$((counter+1))
    if [ $counter -gt 10 ]; then
      exit 1
    fi
  done

  # install mitmproxy certificate as CA
  sudo mkdir /usr/local/share/ca-certificates/extra
  sudo openssl x509 -in /home/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem -inform PEM -out ~/mitmproxy-ca-cert.crt
  sudo cat ~/mitmproxy-ca-cert.crt >> /etc/ssl/certs/ca-certificates.crt
  sudo dpkg-reconfigure -p critical ca-certificates
  sudo update-ca-certificates

  # setup global redirection
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sysctl -w net.ipv6.conf.all.forwarding=1
  sudo sysctl -w net.ipv4.conf.all.send_redirects=0
  sudo iptables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner mitmproxyuser --dport 80 -j REDIRECT --to-port 8080
  sudo iptables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner mitmproxyuser --dport 443 -j REDIRECT --to-port 8080
  sudo ip6tables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner mitmproxyuser --dport 80 -j REDIRECT --to-port 8080
  sudo ip6tables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner mitmproxyuser --dport 443 -j REDIRECT --to-port 8080

elif [ "$RUNNER_OS" = "Windows" ]; then

  echo "Windows is not supported yet"
  exit 1

else

  echo "Unknown OS: $RUNNER_OS"
  exit 1

fi

echo "--all done--"
