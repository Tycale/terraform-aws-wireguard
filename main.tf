terraform {
  required_version = ">= 0.13"

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    template = {
      source = "hashicorp/template"
    }
  }
}

data "template_file" "wg_client_data_json" {
  template = file("${path.module}/templates/client-data.tpl")
  count    = length(var.wg_clients)

  vars = {
    client_name          = var.wg_clients[count.index].name
    client_pub_key       = var.wg_clients[count.index].public_key
    client_ip            = var.wg_clients[count.index].client_ip
    persistent_keepalive = var.wg_persistent_keepalive
  }
}

# Automatically find the latest version of our operating system image (e.g. Ubuntu)
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["${var.ami_prefix}-${var.ami_release}-${var.ami_arch}-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = [var.ami_owner_id]
}

# turn the sg into a sorted list of string
locals {
  sg_wireguard_external = sort([aws_security_group.sg_wireguard_external.id])
}

# clean up and concat the above wireguard default sg with the additional_security_group_ids
locals {
  security_groups_ids = compact(concat(var.additional_security_group_ids, local.sg_wireguard_external))
}

locals {
  launch_name_prefix = "wireguard-${var.env}-"
}

resource "aws_launch_template" "wireguard_launch_config" {
  name_prefix   = local.launch_name_prefix
  image_id      = var.ami_id == null ? data.aws_ami.ubuntu.id : var.ami_id
  instance_type = var.instance_type
  key_name      = var.ssh_key_id
  iam_instance_profile {
    arn = (var.use_eip || var.install_ssm ? aws_iam_instance_profile.wireguard_profile[0].arn : null)
  }

  user_data = base64encode(templatefile("${path.module}/templates/user-data.txt", {
    wg_server_private_key = data.aws_ssm_parameter.wg_server_private_key.value
    wg_server_net         = var.wg_server_net
    wg_server_port        = var.wg_server_port
    peers                 = join("\n", data.template_file.wg_client_data_json.*.rendered)
    use_eip               = var.use_eip ? "enabled" : "disabled"
    install_ssm           = var.install_ssm ? "enabled" : "disabled"
    eip_id                = var.eip_id
    wg_server_interface   = var.wg_server_interface
    arch                  = var.ami_arch
  }))

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = local.security_groups_ids
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      launch-template-name = local.launch_name_prefix
      project              = "wireguard"
      env                  = var.env
      tf-managed           = "True"
    }
  }
}

resource "aws_autoscaling_group" "wireguard_asg" {
  name                 = aws_launch_template.wireguard_launch_config.name
  min_size             = var.asg_min_size
  desired_capacity     = var.asg_desired_capacity
  max_size             = var.asg_max_size
  vpc_zone_identifier  = var.subnet_ids
  health_check_type    = "EC2"
  termination_policies = ["OldestLaunchConfiguration", "OldestInstance"]
  target_group_arns    = var.target_group_arns

  launch_template {
    id      = aws_launch_template.wireguard_launch_config.id
    version = aws_launch_template.wireguard_launch_config.latest_version
  }

  lifecycle {
    create_before_destroy = true
  }

  instance_refresh {
    strategy = "Rolling"
  }

  tag {
    key                 = "Name"
    value               = aws_launch_template.wireguard_launch_config.name
    propagate_at_launch = true
  }

  tag {
    key                 = "env"
    value               = var.env
    propagate_at_launch = true
  }
}

