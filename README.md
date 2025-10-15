# 1) 准备环境（已装 awscli v2 即可），再装些小工具
sudo apt update && sudo apt install -y jq unzip ca-certificates openssh-client curl

# 2) 配置
cp .env.example .env
# 打开 .env，填好区域/子网/磁盘/EIP等（密钥建议不写在文件里，优先用 `aws configure`）

# 3) 运行
chmod +x create-ec2.sh terminate-ec2.sh
./create-ec2.sh

# 4) 需要终止时
./terminate-ec2.sh
