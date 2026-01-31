# 步骤 1：更新软件源并安装添加 PPA 所需的工具
sudo apt update -y
sudo apt install -y software-properties-common

# 步骤 2：添加 PPA
sudo add-apt-repository ppa:ubuntu-toolchain-r/test -y

# 步骤 3：再次更新软件源
sudo apt update -y

# 步骤 4：安装 gcc-13 和 g++-13
sudo apt install -y gcc-13 g++-13