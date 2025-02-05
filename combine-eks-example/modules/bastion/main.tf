data "aws_ami" "az_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "name"
    values = ["al2023-ami-2023*"]
  }
}

resource "aws_instance" "bastion" {
  ami           = data.aws_ami.az_linux.id
  instance_type = var.instance_type

  associate_public_ip_address = true
  key_name                    = var.key_name

  vpc_security_group_ids = [aws_security_group.bastion.id]
  subnet_id              = var.subnet_id

  tags = merge({
    Name = "${var.environment}-bastion"
  }, var.tags)

  user_data = <<-EOF
    #!/bin/bash
    # Add bastion admin users
    %{for user in var.admin_users}
    sudo useradd ${user}
    sudo usermod -aG wheel ${user}
    %{endfor}
    sudo sed -i '/^# %wheel/s/^# //' /etc/sudoers
    # Update the bastion
    sudo yum update -y
    sudo yum upgrade -y
    sudo yum update --security -y
    # Install dependencies
    ## Git
    sudo yum install git -y
    ## Helm 3
    echo "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    ## Kubectl
    echo "Installing Kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    ## Kubectx
    echo "Installing Kubectx..."
    sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx
    sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
    sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
    ## Terraform
    echo "Installing Terraform..."
    sudo yum install -y yum-utils
    sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    sudo yum -y install terraform
    ## Terragrunt
    echo "Installing Terragrunt..."
    curl -L https://github.com/gruntwork-io/terragrunt/releases/latest/download/terragrunt_linux_amd64 -o terragrunt
    sudo install -o root -g root -m 0755 terragrunt /usr/local/bin/terragrunt
    rm terragrunt
    EOF
}

resource "aws_security_group" "bastion" {
  name        = "${var.environment}-bastion"
  description = "Allow SSH inbound traffic and all outbound traffic"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.environment}-bastion"
  }

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
  }

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    to_port     = 0
    protocol    = -1
  }
}

