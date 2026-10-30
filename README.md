sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fL --retry 3 \
  'https://raw.githubusercontent.com/sharkung/xray-install-script/refs/heads/main/xray-debian13.sh' \
  -o xray-debian13.sh
bash -n xray-debian13.sh
chmod 700 xray-debian13.sh
sudo bash ./xray-debian13.sh
